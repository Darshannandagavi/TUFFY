# Project Context

You are helping with an existing software project.

## Instructions

1. First understand the project architecture before answering.
2. Do not modify unrelated files.
3. Reuse the existing project structure and coding style.
4. Make only the minimum required changes.
5. Mention every file that needs to be modified.
6. If additional files are required, ask only for those files.

---

## Project Structure

```text
├── Max.qml
├── README.md
├── inspect_glb.py
├── main.py
├── max_log.txt
├── max_run.txt
├── requirements.txt
└── start_max.bat
```

===============================================================================
FILE: inspect_glb.py
===============================================================================

```python
# inspect_glb.py
import sys, json, struct
from pathlib import Path

def read_glb(path):
    with open(path, "rb") as f:
        magic, version, length = struct.unpack("<III", f.read(12))
        assert magic == 0x46546C67, "Not a GLB"
        chunks = {}
        while f.tell() < length:
            clen, ctype = struct.unpack("<II", f.read(8))
            data = f.read(clen)
            if ctype == 0x4E4F534A:  # JSON
                chunks["json"] = json.loads(data.decode("utf-8"))
            elif ctype == 0x004E4942:  # BIN
                chunks["bin"] = data
        return chunks

def main(path):
    g = read_glb(path)["json"]

    print("=" * 60)
    print(f"GLB: {path}")
    print("=" * 60)

    print(f"\nScenes: {len(g.get('scenes', []))}")
    print(f"Nodes:  {len(g.get('nodes', []))}")
    print(f"Meshes: {len(g.get('meshes', []))}")
    print(f"Skins:  {len(g.get('skins', []))}")
    print(f"Animations: {len(g.get('animations', []))}")
    print(f"Materials: {len(g.get('materials', []))}")

    print("\n--- NODES ---")
    for i, n in enumerate(g.get("nodes", [])):
        name = n.get("name", f"node_{i}")
        kids = n.get("children", [])
        mesh = n.get("mesh")
        skin = n.get("skin")
        print(f"  [{i}] {name!r:40s} children={kids} mesh={mesh} skin={skin}")

    print("\n--- SKINS ---")
    for i, s in enumerate(g.get("skins", [])):
        joints = s.get("joints", [])
        jnames = [g["nodes"][j].get("name", f"n{j}") for j in joints]
        print(f"  [{i}] skeleton={s.get('skeleton')} joints={len(joints)}")
        for jn in jnames:
            print(f"        bone: {jn}")

    print("\n--- ANIMATIONS ---")
    for i, a in enumerate(g.get("animations", [])):
        name = a.get("name", f"anim_{i}")
        channels = a.get("channels", [])
        targets = set()
        for ch in channels:
            t = ch.get("target", {})
            n = t.get("node")
            if n is not None:
                targets.add(g["nodes"][n].get("name", f"n{n}"))
        print(f"  [{i}] {name!r} channels={len(channels)} targets={len(targets)}")
        for tn in sorted(targets):
            print(f"        -> {tn}")

    print("\n--- MORPH TARGETS ---")
    for i, m in enumerate(g.get("meshes", [])):
        for pi, prim in enumerate(m.get("primitives", [])):
            targets = prim.get("targets")
            if targets:
                print(f"  mesh[{i}] {m.get('name')!r} prim[{pi}] has {len(targets)} morph targets")

if __name__ == "__main__":
    main(sys.argv[1])
```

===============================================================================
FILE: main.py
===============================================================================

```python
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
```

===============================================================================
FILE: Max.qml
===============================================================================

```text
import QtQuick
import QtQuick.Window
import QtQuick3D
import QtQuick3D.AssetUtils
import QtCore

Window {
    id: root

    width: 340
    height: 380

    visible: true
    color: "transparent"

    flags: Qt.FramelessWindowHint |
           Qt.WindowStaysOnTopHint |
           Qt.Tool


    // ========================================================
    // CONFIG
    // ========================================================
    property string assetPath:
        Qt.resolvedUrl(
            "assets/Meshy_AI_Robo_Cat_Orb_0921143520_texture.glb"
        )
    property real modelScale: 30


    // ========================================================
    // POSE CHANNELS
    // ========================================================
    property real bob: 0
    property real pitch: 0
    property real yaw: 0
    property real roll: 0
    property real pulse: 1.0
    property real sideMove: 0
    property real jumpY: 0

    property real spinPitch: 0
    property real spinYaw: 0
    property real spinRoll: 0

    property real trackYaw: 0
    property real trackPitch: 0
    property real blink: 0


    // ========================================================
    // DERIVED SCALE (squash & stretch)
    // ========================================================
    readonly property real _jumpStretch: Math.max(0, jumpY) / 100

    readonly property real scaleX:
        pulse * (1 - _jumpStretch * 0.5) * (1 - blink * 0.05)
    readonly property real scaleY:
        pulse * (1 + _jumpStretch * 1.0) * (1 - blink * 0.15)
    readonly property real scaleZ:
        pulse * (1 - _jumpStretch * 0.5) * (1 - blink * 0.05)


    // ========================================================
    // STATE
    // ========================================================
    property string currentState: "idle"
    property bool advancedBusy: false
    property bool chatVisible: false
    property bool dragging: false

    property int thinkDots: 0

    // --------------------------------------------------------
    // Safe reference to the C++ backend (context property).
    // Using a root-level alias avoids scoping issues inside
    // Repeater delegates.
    // --------------------------------------------------------
    readonly property var backend: (typeof maxBackend !== "undefined")
                                  ? maxBackend
                                  : null


    // ========================================================
    // SMOOTHED MOUSE TRACKING
    // ========================================================
    Behavior on trackYaw   { SmoothedAnimation { velocity: 400 } }
    Behavior on trackPitch { SmoothedAnimation { velocity: 400 } }


    // ========================================================
    // WINDOW POSITION PERSISTENCE
    // ========================================================
    Settings {
        id: appSettings
        category: "MaxWindow"
        property alias x: root.x
        property alias y: root.y
        property bool firstRun: true
    }


    // ========================================================
    // 3D SCENE
    // ========================================================
    View3D {
        id: view
        x: 0
        y: 0
        width: parent.width
        height: 260
        camera: camera

        environment: SceneEnvironment {
            clearColor: "transparent"
            backgroundMode: SceneEnvironment.Transparent
        }

        PerspectiveCamera {
            id: camera
            position: Qt.vector3d(0, 0, 220)
            fieldOfView: 30
        }

        DirectionalLight {
            eulerRotation: Qt.vector3d(-35, -25, 0)
            brightness: 1.5
        }
        DirectionalLight {
            eulerRotation: Qt.vector3d(25, 150, 0)
            brightness: 0.8
        }

        RuntimeLoader {
            id: robo
            source: root.assetPath

            scale: Qt.vector3d(
                root.modelScale * root.scaleX,
                root.modelScale * root.scaleY,
                root.modelScale * root.scaleZ
            )

            eulerRotation: Qt.vector3d(
                root.pitch + root.spinPitch + root.trackPitch,
                root.yaw   + root.spinYaw   + root.trackYaw,
                root.roll  + root.spinRoll
            )

            position: Qt.vector3d(
                -((bounds.maximum.x + bounds.minimum.x) / 2) * root.modelScale
                    + root.sideMove,
                -((bounds.maximum.y + bounds.minimum.y) / 2) * root.modelScale
                    + root.bob + root.jumpY,
                -((bounds.maximum.z + bounds.minimum.z) / 2) * root.modelScale
            )
        }
    }


    // ========================================================
    // SHADOW BLOB (soft ground cue, keeps jumps grounded)
    // ========================================================
    Item {
        id: shadowLayer
        z: 1
        anchors.fill: view
        enabled: false

        Rectangle {
            width: 90
            height: 16
            radius: height / 2
            color: "#66000000"
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height - 34 + root.bob * 0.4
            opacity: Math.max(0, 0.28 - root.jumpY / 110)
            scale:   Math.max(0.4, 1 - root.jumpY / 140)
        }
    }


    // ========================================================
    // SPARKLE PARTICLES
    // ========================================================
    Item {
        id: sparkleLayer
        z: 2
        anchors.fill: view
        enabled: false

        function burst(count, color, originX, originY) {
            for (var i = 0; i < count; i++) {
                var angle = Math.random() * Math.PI * 2
                var speed = 50 + Math.random() * 120
                var tx = originX + Math.cos(angle) * speed
                var ty = originY + Math.sin(angle) * speed - 40
                sparkleComponent.createObject(sparkleLayer, {
                    "x": originX,
                    "y": originY,
                    "sparkColor": color,
                    "targetX": tx,
                    "targetY": ty
                })
            }
        }

        function burstAtModel(count, color) {
            burst(count, color, view.width / 2, view.height * 0.45)
        }
    }

    Component {
        id: sparkleComponent

        Rectangle {
            id: sparkleItem
            property color sparkColor: "#FFDD88"
            property real  targetX: 0
            property real  targetY: 0

            width: 5 + Math.random() * 4
            height: width
            radius: width / 2
            color: sparkColor
            opacity: 0

            ParallelAnimation {
                running: true
                NumberAnimation {
                    target: sparkleItem; property: "x"
                    to: sparkleItem.targetX
                    duration: 900; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "y"
                    to: sparkleItem.targetY
                    duration: 900; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "opacity"
                    from: 1; to: 0
                    duration: 900
                }
                NumberAnimation {
                    target: sparkleItem; property: "scale"
                    from: 1.3; to: 0.2
                    duration: 900
                }
            }

            Timer {
                interval: 950
                running: true
                onTriggered: sparkleItem.destroy()
            }
        }
    }


    // ========================================================
    // IDLE ANIMATIONS
    // ========================================================
    SequentialAnimation {
        id: idleFloat
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -4; to: 4
            duration: 2200; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -4
            duration: 2200; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleYaw
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "yaw"
            from: -7; to: 7
            duration: 3600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 7; to: -7
            duration: 3600; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleTilt
        loops: Animation.Infinite
        PauseAnimation { duration: 2200 }
        NumberAnimation {
            target: root; property: "roll"
            from: -3; to: 3
            duration: 1100; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 3; to: -3
            duration: 1100; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 2200 }
    }

    // Blink cycle
    SequentialAnimation {
        id: blinkAnim
        NumberAnimation {
            target: root; property: "blink"
            to: 1; duration: 70
        }
        NumberAnimation {
            target: root; property: "blink"
            to: 0; duration: 130
        }
    }

    Timer {
        id: blinkTimer
        interval: 2500 + Math.random() * 3500
        running: root.currentState === "idle"
        repeat: true
        onTriggered: {
            blinkAnim.restart()
            interval = 2500 + Math.random() * 3500
        }
    }


    // ========================================================
    // THINKING
    // ========================================================
    SequentialAnimation {
        id: thinkingYaw
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "yaw"
            from: -15; to: 15
            duration: 900; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 15; to: -15
            duration: 900; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -6; to: 6
            duration: 700; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 6; to: -6
            duration: 700; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingTilt
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -6; to: 6
            duration: 1400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 1400; easing.type: Easing.InOutSine
        }
    }

    Timer {
        id: thinkDotTimer
        interval: 350
        repeat: true
        running: root.currentState === "thinking"
        onTriggered: root.thinkDots = (root.thinkDots + 1) % 4
    }


    // ========================================================
    // SPEAKING
    // ========================================================
    SequentialAnimation {
        id: speakingPulse
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "pulse"
            from: 1.0; to: 1.045
            duration: 350; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pulse"
            from: 1.045; to: 1.0
            duration: 350; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingMovement
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -3; to: 4
            duration: 400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -3
            duration: 400; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingRoll
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -4; to: 4
            duration: 600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 4; to: -4
            duration: 600; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // HAPPY
    // ========================================================
    SequentialAnimation {
        id: happyAnimation
        loops: 2
        onStarted: sparkleLayer.burstAtModel(20, "#FFDD66")

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "jumpY"
                from: 0; to: 22
                duration: 260; easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                from: 0; to: 360
                duration: 520; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1; to: 1.08
                duration: 260
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "jumpY"
                from: 22; to: 0
                duration: 380; easing.type: Easing.OutBounce
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1.08; to: 1
                duration: 380
            }
        }

        onStopped: root.spinYaw = 0
    }


    // ========================================================
    // ERROR
    // ========================================================
    SequentialAnimation {
        id: errorAnimation
        loops: 3
        NumberAnimation {
            target: root; property: "yaw"
            from: -10; to: 10
            duration: 90; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 10; to: -10
            duration: 90; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: -4; to: 4
            duration: 90
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 4; to: -4
            duration: 90
        }
    }


    // ========================================================
    // LISTENING
    // ========================================================
    SequentialAnimation {
        id: listeningAnimation
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -6; to: 6
            duration: 900; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 900; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // SLEEPY
    // ========================================================
    SequentialAnimation {
        id: sleepyBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -2; to: 3
            duration: 3200; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 3; to: -2
            duration: 3200; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: sleepyDroop
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "pitch"
            from: 0; to: 12
            duration: 2400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 12; to: 0
            duration: 2400; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // EXCITED
    // ========================================================
    SequentialAnimation {
        id: excitedBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -5; to: 8
            duration: 220; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 8; to: -5
            duration: 220; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: excitedSpin
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "spinYaw"
            from: 0; to: 360
            duration: 900; easing.type: Easing.Linear
        }
    }


    // ========================================================
    // CURIOUS
    // ========================================================
    SequentialAnimation {
        id: curiousLook
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 25; duration: 700; easing.type: Easing.OutCubic
        }
        PauseAnimation { duration: 700 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -25; duration: 1000; easing.type: Easing.InOutCubic
        }
        PauseAnimation { duration: 700 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 600; easing.type: Easing.InOutCubic
        }
    }


    // ========================================================
    // CELEBRATING
    // ========================================================
    SequentialAnimation {
        id: celebratingAnim
        loops: 2
        onStarted: sparkleLayer.burstAtModel(28, "#FFD700")

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                from: 0; to: 360
                duration: 900; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                from: 0; to: 18
                duration: 300; easing.type: Easing.OutCubic
            }
        }
        NumberAnimation {
            target: root; property: "jumpY"
            from: 18; to: 0
            duration: 500; easing.type: Easing.OutBounce
        }

        onStopped: root.spinRoll = 0
    }


    // ========================================================
    // RANDOM IDLE ANIMATIONS
    // ========================================================
    SequentialAnimation {
        id: rndSpin360X
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            from: 0; to: 360
            duration: 900; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndSpin360Y
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinYaw"
            from: 0; to: 360
            duration: 900; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndBarrelRoll
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinRoll = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinRoll"
            from: 0; to: 360
            duration: 800; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndDiagonalTilt
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 45; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 45; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 8; duration: 450; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 600 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 450; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 450; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 450; easing.type: Easing.InOutCubic
            }
        }
    }

    SequentialAnimation {
        id: rndNod
        loops: 2
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "spinPitch"
            to: 18; duration: 180; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: -6; duration: 180; easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: 0; duration: 140; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndLookAround
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "spinYaw"
            to: 35; duration: 500; easing.type: Easing.OutCubic
        }
        PauseAnimation { duration: 500 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -35; duration: 800; easing.type: Easing.InOutCubic
        }
        PauseAnimation { duration: 500 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 500; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndBounce
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "jumpY"
            to: -8; duration: 180; easing.type: Easing.InQuad
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 30; duration: 260; easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 0; duration: 520; easing.type: Easing.OutBounce
        }
    }

    SequentialAnimation {
        id: rndWiggle
        loops: 4
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinRoll = 0
            root.spinYaw = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: 12; duration: 90; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 8; duration: 90; easing.type: Easing.InOutSine
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: -12; duration: 90; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -8; duration: 90; easing.type: Easing.InOutSine
            }
        }
    }

    SequentialAnimation {
        id: rndSneeze
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.pulse = 1
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -8; duration: 300; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: -5; duration: 300; easing.type: Easing.OutCubic
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 25; duration: 100; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 12; duration: 100; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.14; duration: 100
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 500; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 500; easing.type: Easing.OutBounce
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 500
            }
        }
    }

    SequentialAnimation {
        id: rndStretch
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.pulse = 1
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -12; duration: 600; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 6; duration: 600; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.08; duration: 600; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 400 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 800; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 800; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 800; easing.type: Easing.InOutCubic
            }
        }
    }

    SequentialAnimation {
        id: rndAttention
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -22; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -6; duration: 450; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 900 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 550; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 550; easing.type: Easing.InOutCubic
            }
        }
    }

    // ---- FLIP (full 360 somersault on X while airborne) ----
    SequentialAnimation {
        id: rndFlip
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(12, "#AADDFF")
        }
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                from: 0; to: 360
                duration: 750; easing.type: Easing.InOutCubic
            }
            SequentialAnimation {
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 42; duration: 375; easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 0; duration: 375; easing.type: Easing.InQuad
                }
            }
        }
    }

    // ---- DANCE (wiggle + spin + hop) ----
    SequentialAnimation {
        id: rndDance
        loops: 3
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.spinRoll = 0
            root.bob = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 30; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinRoll"
                to: 18; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "bob"
                to: 12; duration: 200; easing.type: Easing.OutQuad
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -30; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinRoll"
                to: -18; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "bob"
                to: 0; duration: 200; easing.type: Easing.InQuad
            }
        }
    }


    // ========================================================
    // RANDOM IDLE SCHEDULER
    // ========================================================
    Timer {
        id: randomIdleTimer
        repeat: true
        running: root.currentState === "idle"
        interval: 4000

        onTriggered: {
            if (!root.advancedBusy && !root.dragging)
                root.playRandomIdle()
            randomIdleTimer.interval = 3500 + Math.random() * 5500
        }
    }

    function playRandomIdle() {
        var r = Math.random()
        if (r < 0.10)      rndSpin360X.start()
        else if (r < 0.20) rndSpin360Y.start()
        else if (r < 0.29) rndBarrelRoll.start()
        else if (r < 0.39) rndDiagonalTilt.start()
        else if (r < 0.50) rndNod.start()
        else if (r < 0.61) rndLookAround.start()
        else if (r < 0.70) rndBounce.start()
        else if (r < 0.77) rndWiggle.start()
        else if (r < 0.84) rndStretch.start()
        else if (r < 0.91) rndSneeze.start()
        else if (r < 0.96) rndFlip.start()
        else               rndDance.start()
    }


    // ========================================================
    // NAMED ANIMATION PLAYER (called from backend)
    // ========================================================
    function playNamedAnimation(name) {
        if (root.advancedBusy) {
            root.advancedBusy = false
        }

        switch (name) {
        case "flip":         rndFlip.start();         break
        case "spin360":
        case "spin":
        case "rotate":       rndSpin360Y.start();     break
        case "spin360x":     rndSpin360X.start();     break
        case "barrel":
        case "roll":         rndBarrelRoll.start();   break
        case "diagonal":
        case "tilt":         rndDiagonalTilt.start(); break
        case "jump":
        case "bounce":       rndBounce.start();       break
        case "nod":          rndNod.start();          break
        case "wiggle":       rndWiggle.start();       break
        case "sneeze":       rndSneeze.start();       break
        case "stretch":      rndStretch.start();      break
        case "look":         rndLookAround.start();   break
        case "attention":    rndAttention.start();    break
        case "dance":        rndDance.start();        break
        case "celebrate":    celebratingAnim.start(); break
        case "happy":        happyAnimation.start();  break
        default:
            console.log("Unknown animation:", name)
        }
    }


    // ========================================================
    // BACKEND HOOK
    // ========================================================
    Connections {
        target: root.backend

        function onStateChanged() {
            if (root.backend) root.updateState(root.backend.state)
        }

        function onMoveToTopRightRequested() {
            root.moveToTopRight()
        }

        function onToggleVisibilityRequested() {
            root.visible = !root.visible
            if (root.visible) root.moveToTopRight()
        }

        function onAnimationRequested(name) {
            root.playNamedAnimation(name)
        }
    }


    function stopAnimations() {
        idleFloat.stop();  idleYaw.stop();  idleTilt.stop()
        thinkingYaw.stop(); thinkingBob.stop(); thinkingTilt.stop()
        speakingPulse.stop(); speakingMovement.stop(); speakingRoll.stop()
        happyAnimation.stop()
        errorAnimation.stop()
        listeningAnimation.stop()
        sleepyBob.stop();  sleepyDroop.stop()
        excitedBob.stop(); excitedSpin.stop()
        curiousLook.stop()
        celebratingAnim.stop()
        rndSpin360X.stop(); rndSpin360Y.stop(); rndBarrelRoll.stop()
        rndDiagonalTilt.stop(); rndNod.stop()
        rndLookAround.stop(); rndBounce.stop(); rndWiggle.stop()
        rndSneeze.stop(); rndStretch.stop(); rndAttention.stop()
        rndFlip.stop(); rndDance.stop()
        blinkAnim.stop()
        root.advancedBusy = false
    }

    function resetPose() {
        root.bob = 0
        root.pitch = 0
        root.yaw = 0
        root.roll = 0
        root.pulse = 1.0
        root.sideMove = 0
        root.jumpY = 0
        root.spinPitch = 0
        root.spinYaw = 0
        root.spinRoll = 0
        root.trackPitch = 0
        root.trackYaw = 0
        root.blink = 0
    }

    function updateState(state) {
        root.currentState = state
        stopAnimations()
        resetPose()

        switch (state) {

        case "thinking":
            thinkingYaw.start(); thinkingBob.start(); thinkingTilt.start()
            thinkDotTimer.restart()
            break

        case "speaking":
            speakingPulse.start(); speakingMovement.start(); speakingRoll.start()
            speakTimer.restart()
            break

        case "happy":
            happyAnimation.start()
            happyTimer.restart()
            break

        case "error":
            errorAnimation.start()
            break

        case "listening":
            listeningAnimation.start()
            break

        case "sleepy":
            sleepyBob.start(); sleepyDroop.start()
            break

        case "excited":
            excitedBob.start(); excitedSpin.start()
            break

        case "curious":
            curiousLook.start()
            break

        case "celebrating":
            celebratingAnim.start()
            happyTimer.restart()
            break

        default: // idle
            idleFloat.start(); idleYaw.start(); idleTilt.start()
            randomIdleTimer.interval = 2500
            randomIdleTimer.restart()
        }
    }


    // ========================================================
    // WINDOW HELPERS
    // ========================================================
    function moveToTopRight() {
        var scr = root.screen
        root.x = scr.width - root.width - 20
        root.y = 20
    }

    function snapToEdge() {
        var snapDist = 40
        var scr = root.screen
        if (Math.abs(root.x) < snapDist)
            root.x = 0
        else if (Math.abs(root.x + root.width - scr.width) < snapDist)
            root.x = scr.width - root.width
        if (Math.abs(root.y) < snapDist)
            root.y = 0
        else if (Math.abs(root.y + root.height - scr.height) < snapDist)
            root.y = scr.height - root.height
    }


    // ========================================================
    // MOUSE AREA
    // ========================================================
    MouseArea {
        id: maxMouseArea
        x: 0
        y: 0
        width: parent.width
        height: view.height
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        property real startMouseX: 0
        property real startMouseY: 0
        property real startWindowX: 0
        property real startWindowY: 0
        property real lastMouseX: 0
        property real lastMouseY: 0
        property real dragDistance: 0

        onPressed: function(mouse) {
            startMouseX = mouse.x
            startMouseY = mouse.y
            startWindowX = root.x
            startWindowY = root.y
            lastMouseX = mouse.x
            lastMouseY = mouse.y
            dragDistance = 0
            root.dragging = true
        }

        onPositionChanged: function(mouse) {
            if (pressed) {
                root.x = startWindowX + (mouse.x - startMouseX)
                root.y = startWindowY + (mouse.y - startMouseY)
                dragDistance += Math.abs(mouse.x - lastMouseX)
                              + Math.abs(mouse.y - lastMouseY)
                lastMouseX = mouse.x
                lastMouseY = mouse.y
            } else if (hoverEnabled && !root.advancedBusy
                       && root.currentState === "idle") {
                var cx = width / 2
                var cy = height / 2
                var dx = (mouse.x - cx) / cx
                var dy = (mouse.y - cy) / cy
                root.trackYaw = Math.max(-1, Math.min(1, dx)) * 18
                root.trackPitch = Math.max(-1, Math.min(1, dy)) * 10
            }
        }

        onReleased: function(mouse) {
            root.dragging = false
            if (dragDistance > 120 && !root.advancedBusy) {
                if (Math.random() < 0.5)
                    rndSpin360Y.start()
            }
            snapToEdge()
        }

        onExited: {
            root.trackYaw = 0
            root.trackPitch = 0
        }

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                contextMenu.showAt(mouse.x, mouse.y)
                return
            }
            if (contextMenu.visible) {
                contextMenu.visible = false
                return
            }
            // Left-click → squeak + small pulse reaction
            if (root.backend) root.backend.pokeMax()
            root.pulse = 1.08
            pokePulseTimer.restart()
        }
    }


    // ========================================================
    // CONTEXT MENU
    // ========================================================
    Rectangle {
        id: contextMenu
        visible: false
        z: 100
        width: 170
        height: menuCol.implicitHeight + 8
        color: "#CC1A1A1A"
        border.color: "#444444"
        border.width: 1
        radius: 8

        function showAt(mx, my) {
            x = Math.max(4, Math.min(mx, root.width - width - 4))
            y = Math.max(4, Math.min(my, root.height - height - 4))
            visible = true
        }

        // ----------------------------------------------------
        // handleMenuAction — defined HERE (on contextMenu) so
        // the Repeater delegate can reach it via contextMenu.<fn>.
        // The delegate cannot see `root`, `input`, or `backend`
        // directly; this function runs in contextMenu's scope,
        // which CAN see all of them via the parent chain.
        // ----------------------------------------------------
        function handleMenuAction(act) {
            visible = false

            if (act === "reset") {
                root.moveToTopRight()
            } else if (act === "togglechat") {
                if (root.chatVisible) {
                    root.closeChat()
                } else {
                    root.chatVisible = true
                    if (root.backend) root.backend.setState("listening")
                    input.forceActiveFocus()
                }
            } else if (act === "flip") {
                if (root.backend) root.backend.playAnimation("flip")
            } else if (act === "dance") {
                if (root.backend) root.backend.playAnimation("dance")
            } else if (act === "spin") {
                if (root.backend) root.backend.playAnimation("spin360")
            } else if (act === "sleep") {
                if (root.backend) root.backend.setStateWithSound("sleepy")
            } else if (act === "celebrate") {
                if (root.backend) root.backend.setState("celebrating")
            } else if (act === "quit") {
                Qt.exit(0)
            }
        }

        Column {
            id: menuCol
            anchors.fill: parent
            anchors.margins: 4
            spacing: 1

            Repeater {
                model: [
                    { label: "Reset Position", act: "reset" },
                    { label: root.chatVisible ? "Close Chat" : "Open Chat", act: "togglechat" },
                    { label: "Do a Flip",      act: "flip"  },
                    { label: "Dance",          act: "dance" },
                    { label: "Spin 360",       act: "spin"  },
                    { label: "Sleep",          act: "sleep" },
                    { label: "Celebrate",      act: "celebrate" },
                    { label: "Quit",           act: "quit"  }
                ]

                Rectangle {
                    width: menuCol.width
                    height: 24
                    radius: 4
                    color: menuHover.containsMouse
                           ? "#44FFFFFF"
                           : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: "white"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        id: menuHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: contextMenu.handleMenuAction(modelData.act)
                    }
                }
            }
        }
    }


    // ========================================================
    // CHAT PANEL (with tail)
    // ========================================================
    Item {
        id: chatAnchor
        anchors.top: view.bottom
        anchors.topMargin: -2
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 30
        height: 96
        visible: root.chatVisible
        opacity: root.chatVisible ? 1 : 0
        scale:   root.chatVisible ? 1 : 0.95

        Behavior on opacity { NumberAnimation { duration: 160 } }
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle {
            width: 14
            height: 14
            rotation: 45
            color: "#DD111111"
            x: parent.width / 2 - 7
            y: -7
            z: -1
        }

        Rectangle {
            id: chatPanel
            anchors.fill: parent
            anchors.topMargin: 6
            radius: 16
            color: "#DD111111"
            border.width: 1
            border.color: "#444444"

            Text {
                id: responseText
                x: 12
                y: 7
                width: parent.width - 24
                height: 36
                text: {
                    if (root.currentState === "thinking") {
                        var dots = ["", ".", "..", "..."]
                        return "Thinking" + dots[root.thinkDots]
                    }
                    if (root.currentState === "listening" &&
                        (!root.backend || root.backend.response.length === 0))
                        return "Listening…"
                    return root.backend ? root.backend.response : ""
                }
                color: "white"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            Rectangle {
                id: inputBackground
                x: 10
                y: 52
                width: parent.width - sendButton.width - 28
                height: 27
                radius: 11
                color: "#181818"
                border.width: 1
                border.color: input.activeFocus ? "#666666" : "#333333"

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: 9
                    anchors.rightMargin: 8
                    color: "white"
                    font.pixelSize: 12
                    clip: true
                    selectByMouse: true
                    activeFocusOnPress: true

                    Keys.onReturnPressed: sendMessage()
                    Keys.onEnterPressed:  sendMessage()

                    Text {
                        anchors.fill: parent
                        visible: input.text.length === 0
                        text: "Talk to MAX..."
                        color: "#777777"
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 12
                    }
                }
            }

            Rectangle {
                id: sendButton
                width: 48
                height: 27
                x: parent.width - width - 10
                y: 52
                radius: 11
                color: sendMouse.containsMouse ? "#555555" : "#333333"

                Text {
                    anchors.centerIn: parent
                    text: "Send"
                    color: "white"
                    font.pixelSize: 11
                }

                MouseArea {
                    id: sendMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: sendMessage()
                }
            }
        }
    }


    // ========================================================
    // SEND MESSAGE
    // ========================================================
    function sendMessage() {
        var text = input.text.trim()
        if (text.length === 0) return
        if (root.backend) root.backend.chat(text)
        input.text = ""
        root.chatVisible = true
    }

    function closeChat() {
        root.chatVisible = false
        input.focus = false
        input.text = ""
        if (root.backend) root.backend.setState("idle")
    }


    // ========================================================
    // TIMERS
    // ========================================================
    Timer {
        id: appTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: if (root.backend) root.backend.refreshActiveApp()
    }

    Timer {
        id: speakTimer
        interval: 2800
        repeat: false
        onTriggered: if (root.backend) root.backend.setState("happy")
    }

    Timer {
        id: happyTimer
        interval: 1800
        repeat: false
        onTriggered: if (root.backend) root.backend.setState("idle")
    }
    Timer {
        id: pokePulseTimer
        interval: 180
        repeat: false
        onTriggered: root.pulse = 1.0
    }

    // ========================================================
    // START
    // ========================================================
    Component.onCompleted: {
        if (appSettings.firstRun) {
            moveToTopRight()
            appSettings.firstRun = false
        }
        updateState("idle")
        root.chatVisible = false
    }
}
```

===============================================================================
FILE: max_log.txt
===============================================================================

```text
QDxgiVSyncService not destroyed in time
^C
```

===============================================================================
FILE: max_run.txt
===============================================================================

```text
```

===============================================================================
FILE: README.md
===============================================================================

```md
```

===============================================================================
FILE: requirements.txt
===============================================================================

```text
PySide6-Addons      # contains QtMultimedia → QSoundEffect
```

===============================================================================
FILE: start_max.bat
===============================================================================

```text
@echo off
cd /d F:\MAX_3D
pythonw main.py
exit
```

-------------------------------------------------------------------------------

Generated by ctx

Total Files: 8
