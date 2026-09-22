import os
import sys
import json
import subprocess
import re
import threading
import ctypes
from pathlib import Path

import requests

from PySide6.QtCore import (
    QObject,
    Property,
    Signal,
    Slot,
    QAbstractNativeEventFilter,
)

from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine


OLLAMA_URL = os.getenv(
    "MAX_OLLAMA_URL",
    "http://localhost:11434/api/chat"
)

OLLAMA_CHAT_MODEL = os.getenv(
    "MAX_OLLAMA_MODEL",
    "darshan-jarvis"
)

# Small model used ONLY for emotion + animation classification.
# Keep this as small as possible (1B or less) — it runs in
# parallel with the main reply.
OLLAMA_CLASSIFIER_MODEL = os.getenv(
    "MAX_OLLAMA_CLASSIFIER_MODEL",
    "llama3.2:1b"
)

# How long Ollama keeps the model in VRAM after the last call.
KEEP_ALIVE = "30m"


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
# Read the model's original SYSTEM prompt
# ============================================================

def fetch_model_system_prompt(model_name: str) -> str:
    try:
        r = subprocess.run(
            ["ollama", "show", model_name, "--system"],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass

    try:
        r = subprocess.run(
            ["ollama", "show", model_name, "--modelfile"],
            capture_output=True, text=True, timeout=15,
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

    HOTKEY_ID = 1
    MOD_ALT = 0x0001
    MOD_CONTROL = 0x0002
    VK_M = 0x4D
    WM_HOTKEY = 0x0312

    def __init__(self, callback):
        super().__init__()
        self.callback = callback

    def register(self):
        if os.name != "nt":
            return
        ctypes.windll.user32.RegisterHotKey(
            None, self.HOTKEY_ID,
            self.MOD_CONTROL | self.MOD_ALT,
            self.VK_M,
        )

    def unregister(self):
        if os.name != "nt":
            return
        ctypes.windll.user32.UnregisterHotKey(None, self.HOTKEY_ID)

    def nativeEventFilter(self, eventType, message):
        if os.name != "nt":
            return False, 0
        try:
            msg = ctypes.cast(
                int(message), ctypes.POINTER(MSG)
            ).contents
            if msg.message == self.WM_HOTKEY and msg.wParam == self.HOTKEY_ID:
                self.callback()
                return True, 0
        except Exception:
            pass
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

    _state = "idle"
    _response = ""
    _active_app = "Desktop"
    _error = ""

    HISTORY_WINDOW = 6

    def __init__(self):
        super().__init__()

        self._history = []
        self._history_lock = threading.Lock()
        self._last_animation = "none"

        # Persistent session — reuses TCP connection (saves ~50-200ms/call)
        self._session = requests.Session()

        # Fetch the fine-tune's ORIGINAL system prompt
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

        # Prewarm both models so the first message isn't slow
        threading.Thread(
            target=self._prewarm,
            daemon=True,
        ).start()

    # ========================================================
    # Prewarm — loads both models into VRAM
    # ========================================================
    def _prewarm(self):
        for model in (OLLAMA_CHAT_MODEL, OLLAMA_CLASSIFIER_MODEL):
            try:
                self._session.post(
                    OLLAMA_URL,
                    json={
                        "model": model,
                        "messages": [{"role": "user", "content": "hi"}],
                        "stream": False,
                        "keep_alive": KEEP_ALIVE,
                        "options": {"num_predict": 1},
                    },
                    timeout=120,
                )
                print(f"[MAX] Prewarmed '{model}'")
            except Exception as e:
                print(f"[MAX] Prewarm failed for '{model}': {e}")

    # ========================================================
    # Properties
    # ========================================================
    def getState(self):     return self._state
    def getResponse(self):  return self._response
    def getActiveApp(self): return self._active_app
    def getError(self):     return self._error

    state     = Property(str, getState,     notify=stateChanged)
    response  = Property(str, getResponse,  notify=responseChanged)
    activeApp = Property(str, getActiveApp, notify=activeAppChanged)
    error     = Property(str, getError,     notify=errorChanged)

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

    @Slot(str)
    def playAnimation(self, name):
        self.animationRequested.emit(name)

    @Slot(str)
    def chat(self, user_text):
        user_text = user_text.strip()
        if not user_text:
            return

        self._set_error("")
        self._set_state("thinking")
        self._set_response("")  # clear previous reply

        active_app = self._active_app
        self._append_history("user", user_text)

        threading.Thread(
            target=self._chat_worker,
            args=(user_text, active_app),
            daemon=True,
        ).start()

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
    # STEP 1 — Streaming chat call
    # ========================================================
    def _chat_reply_streaming(self, user_text):
        """
        Streams the chat reply from Ollama and pushes each chunk into
        the QML response property. Returns the final full text.
        """
        messages = [
            {"role": "system", "content": self._original_system_prompt}
        ]
        messages.extend(self._history_snapshot())
        messages.append({"role": "user", "content": user_text})

        payload = {
            "model": OLLAMA_CHAT_MODEL,
            "messages": messages,
            "stream": True,
            "keep_alive": KEEP_ALIVE,
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

                piece = (
                    chunk
                    .get("message", {})
                    .get("content", "")
                )
                if piece:
                    full_reply += piece
                    # Push partial text to QML immediately
                    self._set_response(full_reply)

                if chunk.get("done"):
                    break

        return full_reply.strip()

    # ========================================================
    # STEP 2 — Classifier call (parallel, small model)
    # ========================================================
    def _classify(self, user_text):
        """
        Ask the tiny classifier model for emotion + animation.
        Fires in parallel with the streaming chat call so total
        latency is roughly max(chat, classify) instead of sum.
        """
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
            user += (
                f"PREVIOUS_ANIMATION: {self._last_animation}\n"
            )

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
        print(r)
        raw = (
            data
            .get("message", {})
            .get("content", "")
            .strip()
        )
        parsed = json.loads(raw)

        emotion   = str(parsed.get("emotion", "speaking")).lower()
        animation = str(parsed.get("animation", "none")).lower()

        if emotion not in ALLOWED_EMOTIONS:
            emotion = "speaking"
        if animation not in ALLOWED_ANIMATIONS:
            animation = "none"

        return emotion, animation

    # ========================================================
    # Worker — runs chat + classifier in parallel
    # ========================================================
    def _chat_worker(self, user_text, active_app):

        classify_result = {
            "emotion":   "speaking",
            "animation": "none",
        }

        def classify_worker():
            try:
                emo, anim = self._classify(user_text)
                classify_result["emotion"] = emo
                classify_result["animation"] = anim
            except Exception as e:
                print(f"[MAX] classifier failed: {e}")

        # ---- Fire classifier in parallel with chat ----
        classifier_thread = threading.Thread(
            target=classify_worker,
            daemon=True,
        )
        classifier_thread.start()

        try:
            # ---- Stream chat reply (this is what the user sees) ----
            reply = self._chat_reply_streaming(user_text)
            if reply:
                self._append_history("assistant", reply)

            # ---- Wait for classifier (usually already done) ----
            classifier_thread.join(timeout=8)

            emotion   = classify_result["emotion"]
            animation = classify_result["animation"]
            self._last_animation = animation

            self._set_state(emotion)
            if animation != "none":
                self.animationRequested.emit(animation)

        except Exception as exc:
            self._set_error(str(exc))
            self._set_response(
                "Sorry, Sir. I couldn't reach my brain."
            )
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

    try:
        sys.exit(app.exec())
    finally:
        hotkey.unregister()


if __name__ == "__main__":
    main()