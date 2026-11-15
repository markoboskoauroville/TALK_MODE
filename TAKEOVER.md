# Talk Mode (Mantra): TAKEOVER

**What it is.** A Swift menu-bar app with one window for a real spoken conversation with a Claude Code session, hands
free. Marko talks and pauses; his words are written into the chosen Claude Code session; Claude answers aloud (every
reply ends with `langsay`, spoken through MANTRA_VOICE); while the voice talks Talk Mode does not listen; then it listens
again. The window says where we are in words readable from the camera, three metres away:
LISTENING (green) · HEARING YOU · WRITING IT DOWN · HEARD: "…" · CLAUDE IS THINKING (violet) · SPEAKING (orange) ·
TYPING MODE (grey) · PAUSED · RECORDING / VOICE ENGINE IS DOWN / NO MICROPHONE (red).
Marko's words of 15.11.2026 are in momentaryupdates.md. Repo: markoboskoauroville/TALK_MODE (public, builds on GitHub).

## How it works (app/)

| File | What |
|---|---|
| App.swift | VERSION, the window (TopRow, the big state word, steps ① TALK TO ② MICROPHONE ③ TALK MODE ON \| TYPING, then LANGUAGE EN \| HR, PAUSE, NOISE LIMIT, SAY IT AGAIN), menu bar item `TALK`, ⌃⌥T, `talkmode://` URLs, the debug path (Bench) |
| Talk.swift | the conversation's state machine, sessions and microphones, `state.json` |
| Audio.swift | the input devices (real microphones only: no virtual device, nothing named like a camera), AVAudioEngine at 16 kHz mono, the voice detector (VAD), WAV |
| Voice.swift | MANTRA_VOICE 127.0.0.1:8837 (`/hear`, `/speaking`, `/speak/replay`, `/speak/seen`, `/speak`), the Gate, the spoken phrases |
| ITerm.swift | iTerm2 AppleScript: list sessions (id, name, tty), `write text … newline NO`, 0.6 s, Return |
| Updater.swift | MANTRA_MANIFEST kits/mac-updater, repo TALK_MODE |

- **Listening.** 30 ms frames, an adaptive noise floor (voice = 12 dB over it and over −50 dBFS). An utterance starts after
  90 ms of voice (300 ms before it kept) and ends after **1.3 s** of silence (PAUSE, 0.6–4 s); one whose voice lasts less
  than **0.6 s** is a noise (NOISE LIMIT). Written down by `/hear?lang=en` (HR switch: `lang=hr`).
- **No echo.** The Gate polls `/speaking` every 150 ms: while a reading is on (and not paused) and **400 ms** after it, no
  sample reaches the detector and a half utterance is thrown away. Also closed while `~/.voice/recording.flag` or Voice to
  Text's `take-open` holds a live pid (MicGuard). The app's name holds neither "voice to text" nor "speechify", so its open
  microphone never pauses the voice (voiced.py MicGuard.LISTENERS).
- **The microphone.** The Mac's default input when it is a real microphone (today: External Microphone), else the MacBook
  Pro Microphone; the choice is remembered (② or the menu). Virtual devices (BlackHole, NDI, Zoom, aggregates) and anything
  named like a camera (Sony, Iriun, webcam…) are never listed: the camera's own sound path (Second Take on the Sony body)
  is never touched. Core Audio input is shared, so other recorders keep working.
- **The target.** iTerm2 sessions by tab name; default the most recently active session whose name starts with `mac23`
  (the tty's modification time), remembered by id and by name. Text goes with `write text` to that session only: no focus,
  no keystrokes into any other app.
- **Switching.** Spoken: "real time talk mode" / "talk mode on" → on; "typing mode" / "talk mode off" → off (only when the
  phrase is almost all that was said). In typing mode the microphone stays open but only utterances up to 4 s are written
  down, and only to catch the switch phrase; nothing is sent. Also ⌃⌥T anywhere, the menu bar item, ③, and
  `open -g talkmode://on|off|toggle|repeat|show`. The voice confirms: "Talk mode on. I am listening." / "Typing mode."
- **Repeat.** "say that again", "repeat that", "what did you say" … → `POST /speak/replay` (every reading since his last
  words). Each sent utterance first calls `/speak/seen`, so the replay is the answer to his last words.
- **For sessions.** `~/Library/Application Support/Talk Mode (Mantra)/state.json`: on, state, target, mic, lang, heard.

## Debug path (no microphone permission, no window)

    B="/Applications/Talk Mode (Mantra).app/Contents/MacOS/TalkMode"
    "$B" --list-sessions            # tty, name, id; and the default
    "$B" --list-mics                # * = the one it would use
    "$B" --test-wav clip.wav --to-tty /dev/ttys005 [--lang en] [--pause 1.3] [--fast]

The WAV is fed in real time (100 ms chunks) through the same Gate, detector, `/hear`, phrases and iTerm2 writer; one
JSON line per step (`loaded`, `voice`, `utterance`, `heard`, `sent`, `gate-closed`, `done`). Run it from an iTerm2 tab:
iTerm2 talking to itself needs no Automation permission. Target a throwaway tab running `cat`, never a real session.

## Install (nothing compiles on the Mac)

    gh release download --repo markoboskoauroville/TALK_MODE --pattern app.zip -D /tmp/tm --clobber
    ditto -x -k /tmp/tm/app.zip /Applications && codesign --force -s "Mantra Apps" "/Applications/Talk Mode (Mantra).app"

From v2 on, the app asks at start ("Do you want to update?").

## Permissions (Marko allows them, never answered for him)

1. **Microphone** at the first start (the ears open at once, also in typing mode, for the switch phrase).
2. **Automation → iTerm2** at the first session list or the first sentence sent.

## Icon

TAL / MOD over Claude's icon, "Claude and voice" orange (icon/README.md). Star row `talkmode` in STAR_SWIFT rows.json.
