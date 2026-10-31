import os
import sys
import json
import subprocess
import re
import threading
import ctypes
import time
from pathlib import Path
import requests
from ctypes import wintypes

from PySide6.QtCore import (
    QObject,
    QUrl,
    Property,
    Signal,
    Slot,
    QAbstractNativeEventFilter,
    QTimer,
)

from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

OLLAMA_URL = os.getenv(
    "MAX_OLLAMA_URL",
    "http://localhost:11434/api/chat"
)

# Ollama's dedicated unload endpoint (kept separate for clarity)
OLLAMA_BASE = OLLAMA_URL.rsplit("/api/", 1)[0]

OLLAMA_CHAT_MODEL = os.getenv(
    "MAX_OLLAMA_MODEL",
    "darshan-jarvis"
)

# Small model used ONLY for emotion + animation classification.
# Keep this as small as possible (1B or less) — it runs in
# parallel with the main reply.
OLLAMA_CLASSIFIER_MODEL = os.getenv(
    "MAX_OLLAMA_CLASSIFIER_MODEL",
    "darshan-jarvis"
)

# How long Ollama keeps the model in VRAM after the last call.
# We manage chat model unloading ourselves, so this just covers
# the classifier.
KEEP_ALIVE = "5m"

# Idle timeout (seconds) before unloading the big chat model.
CHAT_IDLE_UNLOAD_SECONDS = 60


# ============================================================
# Allowed animations / emotions
# ============================================================
ALLOWED_ANIMATIONS = [
    "none",
    "flip",
    "spin360",
    "spin360x",
    "barrel",
    "diagonal",
    "jump",
    "nod",
    "wiggle",
    "sneeze",
    "stretch",
    "look",
    "dance",
    "celebrate",
    "attention",
]

ALLOWED_EMOTIONS = [
    "happy",
    "curious",
    "excited",
    "speaking",
    "error",
    "sleepy",
    "listening",
]


CLASSIFIER_SCHEMA = {
    "type": "object",
    "properties": {
        "emotion":   {"type": "string", "enum": ALLOWED_EMOTIONS},
        "animation": {"type": "string", "enum": ALLOWED_ANIMATIONS},
    },
    "required": ["emotion", "animation"],
}


# ============================================================
# Keyword → animation map
# ============================================================
# Fast-path: if the user's message clearly requests a specific
# animation, we don't call the classifier LLM at all.
#
# Each entry is (list_of_phrases, animation_name).
# Matching is case-insensitive and word-boundary aware.
# ============================================================
ANIMATION_KEYWORDS = [
    # ---- FLIP ----
    (["do a flip", "do the flip", "backflip", "back flip",
      "frontflip", "front flip", "somersault", "do a somersault"],
     "flip"),

    # ---- BARREL ROLL ----
    (["barrel roll", "barrelroll", "do a barrel",
      "roll over", "do a roll"],
     "barrel"),

    # ---- SPIN 360 (Y axis) ----
    (["spin 360", "spin360", "360 spin", "spin around",
      "spin once", "full spin", "do a spin", "spin for me"],
     "spin360"),

    # ---- SPIN 360 (X axis) ----
    (["spin on the x", "spin x axis", "spin360x",
      "x axis spin", "front spin"],
     "spin360x"),

    # ---- DIAGONAL TILT ----
    (["diagonal tilt", "tilt sideways", "diagonal",
      "tilt for me", "do a tilt"],
     "diagonal"),

    # ---- DANCE ----
    (["do a dance", "dance for me", "dance", "boogie",
      "groove", "show me a dance", "let's dance"],
     "dance"),

    # ---- CELEBRATE ----
    (["celebrate", "celebration", "victory",
      "yay", "woohoo", "hooray", "do a celebration"],
     "celebrate"),

    # ---- JUMP / BOUNCE ----
    (["do a jump", "jump for me", "jump", "hop",
      "bounce", "do a bounce"],
     "jump"),

    # ---- NOD ----
    (["nod your head", "nod yes", "do a nod",
      "say yes", "nod"],
     "nod"),

    # ---- WIGGLE ----
    (["wiggle", "shake", "shimmy", "do a wiggle"],
     "wiggle"),

    # ---- SNEEZE ----
    (["sneeze", "achoo", "atchoo", "do a sneeze"],
     "sneeze"),

    # ---- STRETCH / YAWN ----
    (["stretch", "yawn", "do a stretch", "wake up"],
     "stretch"),

    # ---- LOOK AROUND ----
    (["look around", "look about", "scan the room",
      "look for me", "do a look"],
     "look"),

    # ---- ATTENTION ----
    (["attention", "focus", "listen up", "look at me",
      "pay attention"],
     "attention"),
]


# ============================================================
# Keyword → emotion quick map (no LLM for obvious cues)
# ============================================================
EMOTION_KEYWORDS = [
    # Happy / polite
    (["thanks", "thank you", "good job", "nice work",
      "well done", "great job", "awesome", "amazing",
      "you're the best", "you are the best"],
     "happy"),

    # Greetings
    (["hello", "hi max", "hey max", "good morning",
      "good evening", "good afternoon", "howdy"],
     "happy"),

    # Apologies → error face
    (["sorry", "my bad", "oops", "my fault"],
     "error"),

    # Sleepy cues
    (["good night", "i'm tired", "im tired", "going to sleep",
      "time to sleep", "let's rest"],
     "sleepy"),
]


def keyword_animation(text: str):
    """
    Returns an animation name if `text` clearly requests one.
    Otherwise returns None and the caller should fall back to
    the LLM classifier.
    """
    t = " " + text.lower().strip() + " "

    # Strip polite prefixes so "please do a flip" still matches
    for prefix in ("please ", "can you ", "could you ", "would you ",
                   "max, ", "max ", "hey "):
        t = t.replace(prefix, " ")

    # Check longest / most specific phrases first; longest wins
    best = None
    best_len = 0
    for phrases, anim in ANIMATION_KEYWORDS:
        for phrase in phrases:
            if (f" {phrase} " in t or f" {phrase}," in t
                    or f" {phrase}." in t or f" {phrase}!" in t
                    or f" {phrase}?" in t):
                if len(phrase) > best_len:
                    best = anim
                    best_len = len(phrase)
    return best


def keyword_emotion(text: str):
    """
    Returns an emotion name if `text` clearly implies one.
    Otherwise None.
    """
    t = text.lower().strip()
    for phrases, emo in EMOTION_KEYWORDS:
        for phrase in phrases:
            if phrase in t:
                return emo
    return None


# ============================================================
# Read the model's original SYSTEM prompt
# ============================================================

def fetch_model_system_prompt(model_name: str) -> str:
    try:
        r = subprocess.run(
            ["ollama", "show", model_name, "--system"],
            capture_output=True, text=True, timeout=15,
            creationflags=CREATE_NO_WINDOW,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass

    try:
        r = subprocess.run(
            ["ollama", "show", model_name, "--modelfile"],
            capture_output=True, text=True, timeout=15,
            creationflags=CREATE_NO_WINDOW,
        )
        if r.returncode == 0:
            text = r.stdout
            m = re.search(r'SYSTEM\s+"""(.*?)"""', text, re.DOTALL)
            if m:
                return m.group(1).strip()
            m = re.search(r'SYSTEM\s+"(.*?)"', text, re.DOTALL)
            if m:
                return m.group(1).strip()
    except Exception:
        pass

    return ""


# ============================================================
# Windows global hotkey
# ============================================================


class HotkeyFilter(QAbstractNativeEventFilter):

    HOTKEY_ID  = 1
    MOD_ALT    = 0x0001
    MOD_CONTROL = 0x0002
    MOD_NOREPEAT = 0x4000      # important — stops key-repeat spam
    VK_SPACE   = 0x20
    WM_HOTKEY  = 0x0312

    def __init__(self, callback):
        super().__init__()
        self.callback = callback
        self._registered = False

    def register(self):
        if os.name != "nt":
            return
        ok = ctypes.windll.user32.RegisterHotKey(
            None,
            self.HOTKEY_ID,
            self.MOD_CONTROL | self.MOD_ALT | self.MOD_NOREPEAT,
            self.VK_SPACE,
        )
        self._registered = bool(ok)
        print(f"[MAX] Ctrl+Alt+Space registered: {self._registered}")

    def unregister(self):
        if os.name != "nt" or not self._registered:
            return
        ctypes.windll.user32.UnregisterHotKey(None, self.HOTKEY_ID)
        self._registered = False

    def nativeEventFilter(self, eventType, message):
        if os.name != "nt":
            return False, 0
        try:
            # `message` is a void* to a native MSG struct.
            # Cast it with ctypes directly — no int() conversion.
            msg = ctypes.cast(
                message.__int__() if hasattr(message, "__int__") else message,
                ctypes.POINTER(wintypes.MSG),
            ).contents

            if msg.message == self.WM_HOTKEY and msg.wParam == self.HOTKEY_ID:
                # Never call user code directly inside the filter.
                # Schedule it on the next event loop tick.
                QTimer.singleShot(0, self.callback)
                return True, 0
        except Exception as e:
            print(f"[MAX] hotkey filter error: {e}")
        return False, 0


class MSG(ctypes.Structure):
    _fields_ = [
        ("hwnd", ctypes.c_void_p),
        ("message", ctypes.c_uint),
        ("wParam", ctypes.c_size_t),
        ("lParam", ctypes.c_ssize_t),
        ("time", ctypes.c_uint),
        ("pt_x", ctypes.c_long),
        ("pt_y", ctypes.c_long),
    ]


# ============================================================
# Sound player — minimal test version
# ============================================================
# ============================================================
# Sound player — QMediaPlayer version (MP3-safe)
# ============================================================

# ============================================================
# Sound aliases
# ============================================================
# Maps an animation/emotion name to an actual sound file (minus
# extension). Lets you keep long downloaded filenames without
# renaming them on disk.
#
# The SoundPlayer will try  <alias_or_name>.wav/.mp3/.ogg/.flac
# ============================================================
SOUND_ALIASES = {
    # ---- Cartoon pop: bouncy / jumpy motions ----
    "jump":       "creatorshome-pop-cartoon-328167",
    "bounce":     "creatorshome-pop-cartoon-328167",
    "flip":       "creatorshome-pop-cartoon-328167",
    "barrel":     "creatorshome-pop-cartoon-328167",
    "spin360":    "creatorshome-pop-cartoon-328167",
    "spin360x":   "creatorshome-pop-cartoon-328167",
    "diagonal":   "creatorshome-pop-cartoon-328167",
    "happy":      "creatorshome-pop-cartoon-328167",
    "celebrate":  "creatorshome-pop-cartoon-328167",
    "dance":      "creatorshome-pop-cartoon-328167",

    # ---- Squeaky toy: quick snappy / poking motions ----
    "nod":        "floraphonic-baby-squeak-toy-2-183912",
    "wiggle":     "floraphonic-baby-squeak-toy-2-183912",
    "attention":  "floraphonic-baby-squeak-toy-2-183912",
    "look":       "floraphonic-baby-squeak-toy-2-183912",
    "sneeze":     "floraphonic-baby-squeak-toy-2-183912",
    "stretch":    "floraphonic-baby-squeak-toy-2-183912",
    "error":      "floraphonic-baby-squeak-toy-2-183912",

    # ---- Left-click poke (we'll add the slot below) ----
    "poke":       "floraphonic-baby-squeak-toy-2-183912",
}

class SoundPlayer(QObject):
    """
    Plays SFX files (mp3 / wav / ogg / flac) using QMediaPlayer.
    Each sound gets its own player + audio output so overlapping
    effects don't cut each other off.
    """

    def __init__(self, sounds_dir: Path):
        super().__init__()
        self._sounds_dir = sounds_dir
        self._cache: dict = {}
        self._enabled = sounds_dir.exists()

        if not self._enabled:
            print(f"[MAX] sounds folder missing: {sounds_dir}")
        else:
            print(f"[MAX] sounds folder: {sounds_dir}")

    def _get(self, name: str):
        if not self._enabled:
            return None
        if name in self._cache:
            return self._cache[name]

        # Resolve alias (e.g. "jump" -> "creatorshome-pop-cartoon-328167")
        file_stem = SOUND_ALIASES.get(name, name)

        for ext in (".wav", ".mp3", ".ogg", ".flac"):
            path = self._sounds_dir / f"{file_stem}{ext}"
            if path.exists():
                player = QMediaPlayer()
                audio_out = QAudioOutput()
                audio_out.setVolume(0.7)
                player.setAudioOutput(audio_out)
                player.setSource(QUrl.fromLocalFile(str(path)))

                # Rewind when the clip finishes so it can be replayed.
                player.mediaStatusChanged.connect(
                    lambda status, p=player: self._on_status(p, status)
                )

                self._cache[name] = (player, audio_out)
                print(f"[MAX] loaded sound: {path.name}")
                return self._cache[name]

        print(f"[MAX] no sound file for '{name}'")
        self._cache[name] = None
        return None

    @staticmethod
    def _on_status(player, status):
        if status == QMediaPlayer.EndOfMedia:
            player.setPosition(0)

    def play(self, name: str):
        if not name or name == "none":
            return
        entry = self._get(name)
        if entry is None:
            return
        player, _ = entry
        player.setPosition(0)
        player.play()
# ============================================================
# MAX Backend
# ============================================================

class MaxBackend(QObject):

    stateChanged = Signal()
    responseChanged = Signal()
    activeAppChanged = Signal()
    errorChanged = Signal()

    moveToTopRightRequested = Signal()
    toggleVisibilityRequested = Signal()
    animationRequested = Signal(str)
    openChatRequested = Signal()
    chatModelLoadedChanged = Signal()

    _state = "idle"
    _response = ""
    _active_app = "Desktop"
    _error = ""
    _chat_model_loaded = False

    HISTORY_WINDOW = 6

    def __init__(self):
        super().__init__()

        self._history = []
        self._history_lock = threading.Lock()
        self._last_animation = "none"

        # Model load/unload bookkeeping
        self._chat_model_loaded = False
        self._chat_model_lock = threading.Lock()
        self._last_chat_activity = 0.0

        # Persistent session — reuses TCP connection
        self._session = requests.Session()
        sounds_dir = Path(__file__).resolve().parent / "assets" / "sounds"
        self._sounds = SoundPlayer(sounds_dir)
        # Fetch the fine-tune's ORIGINAL system prompt (cheap, no VRAM)
        self._original_system_prompt = fetch_model_system_prompt(
            OLLAMA_CHAT_MODEL
        )
        if self._original_system_prompt:
            print(
                f"[MAX] Loaded original system prompt "
                f"({len(self._original_system_prompt)} chars)."
            )
        else:
            print(
                f"[MAX] WARNING: no SYSTEM prompt found for "
                f"'{OLLAMA_CHAT_MODEL}'."
            )
            self._original_system_prompt = (
                "You are a helpful desktop assistant. "
                "Address the user as Sir."
            )

        # Prewarm the classifier
        threading.Thread(
            target=self._prewarm_classifier,
            daemon=True,
        ).start()

        # Idle unload timer — checked every 5 seconds
        self._idle_timer = QTimer(self)
        self._idle_timer.setInterval(5000)
        self._idle_timer.timeout.connect(self._check_idle_unload)
        self._idle_timer.start()

    # ========================================================
    # Prewarm
    # ========================================================
    def _prewarm_classifier(self):
        try:
            self._session.post(
                OLLAMA_URL,
                json={
                    "model": OLLAMA_CLASSIFIER_MODEL,
                    "messages": [{"role": "user", "content": "hi"}],
                    "stream": False,
                    "keep_alive": KEEP_ALIVE,
                    "options": {"num_predict": 1},
                },
                timeout=120,
            )
            print(f"[MAX] Prewarmed '{OLLAMA_CLASSIFIER_MODEL}'")
        except Exception as e:
            print(f"[MAX] Prewarm failed for classifier: {e}")

    # ========================================================
    # Chat model load / unload helpers
    # ========================================================
    def _load_chat_model(self):
        with self._chat_model_lock:
            if self._chat_model_loaded:
                return
            try:
                print(f"[MAX] Loading '{OLLAMA_CHAT_MODEL}' into VRAM...")
                self._session.post(
                    OLLAMA_URL,
                    json={
                        "model": OLLAMA_CHAT_MODEL,
                        "messages": [{"role": "user", "content": "hi"}],
                        "stream": False,
                        "keep_alive": -1,
                        "options": {"num_predict": 1},
                    },
                    timeout=300,
                )
                self._chat_model_loaded = True
                self.chatModelLoadedChanged.emit()
                print(f"[MAX] '{OLLAMA_CHAT_MODEL}' loaded.")
            except Exception as e:
                print(f"[MAX] Failed to load chat model: {e}")
                raise

    def _unload_chat_model(self):
        with self._chat_model_lock:
            if not self._chat_model_loaded:
                return
            try:
                print(f"[MAX] Unloading '{OLLAMA_CHAT_MODEL}' from VRAM...")
                self._session.post(
                    OLLAMA_URL,
                    json={
                        "model": OLLAMA_CHAT_MODEL,
                        "messages": [],
                        "keep_alive": 0,
                    },
                    timeout=30,
                )
            except Exception as e:
                print(f"[MAX] Unload request failed: {e}")
            self._chat_model_loaded = False
            self.chatModelLoadedChanged.emit()
            print(f"[MAX] '{OLLAMA_CHAT_MODEL}' unloaded.")

    def _check_idle_unload(self):
        if not self._chat_model_loaded:
            return
        if self._state in ("thinking", "speaking"):
            return
        if self._last_chat_activity <= 0:
            return
        idle_for = time.monotonic() - self._last_chat_activity
        if idle_for >= CHAT_IDLE_UNLOAD_SECONDS:
            print(f"[MAX] Idle for {idle_for:.0f}s — unloading chat model.")
            threading.Thread(
                target=self._unload_chat_model,
                daemon=True,
            ).start()

    # ========================================================
    # Properties
    # ========================================================
    def getState(self):     return self._state
    def getResponse(self):  return self._response
    def getActiveApp(self): return self._active_app
    def getError(self):     return self._error
    def getChatModelLoaded(self): return self._chat_model_loaded

    state           = Property(str, getState,           notify=stateChanged)
    response        = Property(str, getResponse,        notify=responseChanged)
    activeApp       = Property(str, getActiveApp,       notify=activeAppChanged)
    error           = Property(str, getError,           notify=errorChanged)
    chatModelLoaded = Property(bool, getChatModelLoaded, notify=chatModelLoadedChanged)

    # ========================================================
    # Setters
    # ========================================================
    def _set_state(self, value):
        if self._state != value:
            self._state = value
            self.stateChanged.emit()

    def _set_response(self, value):
        self._response = value
        self.responseChanged.emit()

    def _set_active_app(self, value):
        if self._active_app != value:
            self._active_app = value
            self.activeAppChanged.emit()

    def _set_error(self, value):
        if self._error != value:
            self._error = value
            self.errorChanged.emit()

    # ========================================================
    # QML slots
    # ========================================================
    @Slot(str)
    def setState(self, state):
        self._set_state(state)

    @Slot()
    def refreshActiveApp(self):
        self._set_active_app(self._get_active_windows_app())

    @Slot()
    def showTopRight(self):
        self.moveToTopRightRequested.emit()

    @Slot()
    def toggleMax(self):
        self.toggleVisibilityRequested.emit()

    @Slot()
    def requestOpenChat(self):
        self.openChatRequested.emit()

    @Slot(str)
    def playAnimation(self, name):
        self.animationRequested.emit(name)
        self._sounds.play(name)

    @Slot()
    def pokeMax(self):
        """Left-click on MAX → squeak."""
        self._sounds.play("poke")
    
    @Slot(str)
    def chat(self, user_text):
        user_text = user_text.strip()
        if not user_text:
            return

        self._set_error("")
        self._set_state("thinking")
        self._set_response("")

        # ---- Fast-path animation: fire immediately ----
        kw_anim = keyword_animation(user_text)
        if kw_anim:
            print(f"[MAX] immediate keyword animation: {kw_anim}")
            self.animationRequested.emit(kw_anim)
            self._last_animation = kw_anim

        active_app = self._active_app
        self._append_history("user", user_text)
        self._last_chat_activity = time.monotonic()

        threading.Thread(
            target=self._chat_worker,
            args=(user_text, active_app),
            daemon=True,
        ).start()

    
    
    @Slot(str)
    def setStateWithSound(self, state):
        """
        Like setState(), but also fires a sound if the state
        has an entry in SOUND_ALIASES (or a file named <state>).
        """
        self._set_state(state)
        # SoundPlayer.play() is safe to call for any name —
        # if no file/alias exists, it logs and returns.
        self._sounds.play(state)
    # ========================================================
    # History
    # ========================================================
    def _append_history(self, role, content):
        with self._history_lock:
            self._history.append({"role": role, "content": content})
            if len(self._history) > self.HISTORY_WINDOW * 2:
                self._history = self._history[-self.HISTORY_WINDOW * 2:]

    def _history_snapshot(self):
        with self._history_lock:
            return list(self._history[-self.HISTORY_WINDOW:])

    # ========================================================
    # Streaming chat call
    # ========================================================
    def _chat_reply_streaming(self, user_text):
        messages = [
            {"role": "system", "content": self._original_system_prompt}
        ]
        messages.extend(self._history_snapshot())
        messages.append({"role": "user", "content": user_text})

        payload = {
            "model": OLLAMA_CHAT_MODEL,
            "messages": messages,
            "stream": True,
            "keep_alive": -1,
            "options": {
                "temperature": 0.7,
                "num_predict": 220,
            },
        }

        full_reply = ""

        with self._session.post(
            OLLAMA_URL,
            json=payload,
            stream=True,
            timeout=180,
        ) as r:
            r.raise_for_status()
            for raw_line in r.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                try:
                    chunk = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue

                piece = chunk.get("message", {}).get("content", "")
                if piece:
                    full_reply += piece
                    self._set_response(full_reply)

                if chunk.get("done"):
                    break

        return full_reply.strip()

    # ========================================================
    # Classifier (LLM fallback — only when keywords miss)
    # ========================================================
    def _classify(self, user_text):
        system = (
            "You classify a desktop robot's reaction to a user message.\n"
            "\n"
            "EMOTION — one of: happy, curious, excited, speaking, error, "
            "sleepy, listening.\n"
            "\n"
            "ANIMATION — pick one ONLY if the user explicitly asks for a "
            "physical gesture, OR says 'again' / 'repeat' / 'one more "
            "time' and a PREVIOUS_ANIMATION is given. Otherwise 'none'.\n"
            "\n"
            "Animation reference:\n"
            "  flip      - somersault / backflip / frontflip\n"
            "  spin360   - spin / rotate around once\n"
            "  spin360x  - spin on the X axis\n"
            "  barrel    - barrel roll\n"
            "  diagonal  - diagonal tilt\n"
            "  jump      - jump / hop / bounce\n"
            "  nod       - nod yes\n"
            "  wiggle    - wiggle / shake\n"
            "  sneeze    - sneeze\n"
            "  stretch   - stretch / yawn\n"
            "  look      - look around\n"
            "  dance     - dance\n"
            "  celebrate - celebrate / victory\n"
            "  attention - turn to look\n"
            "  none      - no gesture (default)\n"
            "\n"
            "Output ONLY valid JSON matching the schema."
        )

        user = f"USER_MESSAGE: {user_text}\n"

        if self._last_animation and self._last_animation != "none":
            user += f"PREVIOUS_ANIMATION: {self._last_animation}\n"

        payload = {
            "model": OLLAMA_CLASSIFIER_MODEL,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user",   "content": user},
            ],
            "stream": False,
            "format": CLASSIFIER_SCHEMA,
            "keep_alive": KEEP_ALIVE,
            "options": {
                "temperature": 0.1,
                "num_predict": 40,
            },
        }

        r = self._session.post(OLLAMA_URL, json=payload, timeout=60)
        r.raise_for_status()
        data = r.json()
        raw = data.get("message", {}).get("content", "").strip()
        parsed = json.loads(raw)

        emotion   = str(parsed.get("emotion", "speaking")).lower()
        animation = str(parsed.get("animation", "none")).lower()

        if emotion not in ALLOWED_EMOTIONS:
            emotion = "speaking"
        if animation not in ALLOWED_ANIMATIONS:
            animation = "none"

        return emotion, animation

    # ========================================================
    # Worker — lazy load chat model, run chat + classifier
    # ========================================================
    def _chat_worker(self, user_text, active_app):

        # Was an animation already fired by the keyword fast-path
        # in chat()?  If so, don't call the classifier for animation.
        kw_anim = keyword_animation(user_text)
        kw_emo  = keyword_emotion(user_text) if not kw_anim else None

        classify_result = {
            "emotion":   kw_emo if kw_emo else "speaking",
            "animation": kw_anim if kw_anim else "none",
        }

        classifier_thread = None

        # Only call the LLM classifier when keywords didn't cover it.
        if not kw_anim and not kw_emo:
            def classify_worker():
                try:
                    emo, anim = self._classify(user_text)
                    classify_result["emotion"] = emo
                    classify_result["animation"] = anim
                except Exception as e:
                    print(f"[MAX] classifier failed: {e}")

            classifier_thread = threading.Thread(
                target=classify_worker,
                daemon=True,
            )
            classifier_thread.start()
        else:
            if kw_anim:
                print(f"[MAX] keyword animation hit: {kw_anim} — skipping classifier")
            elif kw_emo:
                print(f"[MAX] keyword emotion hit: {kw_emo} — skipping classifier")

        try:
            # ---- Lazy load chat model ----
            self._load_chat_model()

            # ---- Stream chat reply ----
            reply = self._chat_reply_streaming(user_text)
            if reply:
                self._append_history("assistant", reply)

            self._last_chat_activity = time.monotonic()

            # ---- Wait for classifier if it ran ----
            if classifier_thread is not None:
                classifier_thread.join(timeout=8)

            emotion   = classify_result["emotion"]
            animation = classify_result["animation"]
            self._last_animation = animation

            self.setStateWithSound(emotion)


            # Only emit the animation if the keyword fast-path
            # in chat() didn't already fire it.
            if animation != "none" and not kw_anim:
                self.animationRequested.emit(animation)

        except Exception as exc:
            self._set_error(str(exc))
            self._set_response("Sorry, Sir. I couldn't reach my brain.")
            self._set_state("error")

    # ========================================================
    # Active Windows app
    # ========================================================
    def _get_active_windows_app(self):
        if os.name != "nt":
            return "Desktop"
        try:
            user32 = ctypes.windll.user32
            kernel32 = ctypes.windll.kernel32

            hwnd = user32.GetForegroundWindow()
            if not hwnd:
                return "Desktop"

            process_id = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(
                hwnd, ctypes.byref(process_id)
            )

            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION,
                False,
                process_id.value,
            )
            if not handle:
                return "Desktop"

            try:
                buffer_size = ctypes.c_ulong(1024)
                buffer = ctypes.create_unicode_buffer(1024)
                success = kernel32.QueryFullProcessImageNameW(
                    handle, 0, buffer, ctypes.byref(buffer_size)
                )
                if not success:
                    return "Desktop"
                executable = buffer.value
                if not executable:
                    return "Desktop"
                return Path(executable).stem
            finally:
                kernel32.CloseHandle(handle)

        except Exception:
            return "Desktop"

    # ========================================================
    # Cleanup
    # ========================================================
    @Slot()
    def shutdown(self):
        try:
            self._unload_chat_model()
        except Exception:
            pass


# ============================================================
# Main
# ============================================================

def main():
    app = QGuiApplication(sys.argv)
    app.setOrganizationName("MAX_Desktop")
    app.setApplicationName("MAX_Assistant")

    engine = QQmlApplicationEngine()
    backend = MaxBackend()
    engine.rootContext().setContextProperty("maxBackend", backend)

    hotkey = HotkeyFilter(backend.toggleMax)
    app.installNativeEventFilter(hotkey)
    hotkey.register()

    qml_file = Path(__file__).resolve().parent / "Max.qml"
    engine.load(str(qml_file))

    if not engine.rootObjects():
        hotkey.unregister()
        sys.exit(1)

    backend.refreshActiveApp()

    app.aboutToQuit.connect(backend.shutdown)

    try:
        sys.exit(app.exec())
    finally:
        hotkey.unregister()
        try:
            backend.shutdown()
        except Exception:
            pass


if __name__ == "__main__":
    main()