# Talk Mode (Mantra): TAKEOVER

**v13, 15.11.2026: HEARD does not linger (Marko: "annoying text ... heard mother what's happening again").** HEARD shows the words while they are sent and 6 s after, fades out over 0.6 s, then `heard` is empty (also in state.json). Talk.swift `heardChanged`.

**v12, 15.11.2026: RED EDGE while Space Mode is on (app/RedEdge.swift: click-through overlay per screen, all Spaces, above full screen; 7 pt border 70 % + 30 pt falloff 38 % to 0, Sony REC-frame style; removed when SpaceMode.on turns false, so on every exit path incl. the watchdog; `--edge-shot f.png --size WxH` renders it). Always on screen, and plain state words (Marko: "It going out of the screen and is just staying there ... when I change monitors ... it is falling out", "it says paused recording. What is paused?").**
- app/WindowFit.swift: the window is always fully inside the visibleFrame (menu bar, Dock excluded) of the screen that holds most of it. `WindowFit.fit` (pure): shrink width/height to the screen (the minimum size shrinks too when the screen is smaller than 720x500), then move inside. Runs 0.35 s after every move/resize (windowDidMove/Resize/EndLiveResize/ChangeScreen), on `NSApplication.didChangeScreenParametersNotification` (at once and again after 1.2 s, while macOS settles), on wake (+2 s), and on launch. The frame is remembered per screen configuration (UserDefaults `frameBySetup`, key = sorted screen sizes and places); a known setup returns to its remembered place, a new one is fitted. Full screen is left alone. Root is a ScrollView whose content is at least the window's height: on every normal size nothing scrolls, on a too-small screen the bottom (switches, SEND NOW) is one scroll away.
- State words (Talk.swift TalkState.word, `plain` = the sentence in state.json): TALK MODE IS OFF · LISTENING (manual: MANUAL · PRESS SPACE TO TALK) · I HEAR YOU · WRITING IT DOWN · CLAUDE IS THINKING · CLAUDE IS SPEAKING · RECORDING… (Talk Mode's own take, red) · VOX IS RECORDING — I WAIT (Voice to Text's ~/.voice/recording.flag or take-open is alive; Talk Mode is deaf until it ends) · VOICE ENGINE IS DOWN · NO MICROPHONE · NO SESSION CHOSEN · SENDING. "PAUSED" is gone.
- Proof without a screen: `TalkMode --preview <state> --shot f.png --size WxH --visible WxH` (the window is fitted by the same rule on a simulated screen and the result printed).
- Queen: "talk mode status" answers state.json's `plain` sentence (groq_ai_studio ops_hands.py `_tm_summary`, skill talk-mode.md).

**v11, 15.11.2026: macOS switches, SPACE MODE, a simpler window (Marko: "a typical switch in the Mac OS ... I want to see them everywhere", "space mode ... my keyboard and mouse outputs are disabled completely ... space reacts wherever is the focus", "put this blocking banner you are using when macro is running, so I can also press and take over", "language, ears ... I don't need these things").**
- The window: the state word, HEARD, SEND NOW, ① TALK TO, ② the TALK MODE switch, the AUTO switch (off = MANUAL) and the SPACE MODE switch: real macOS switches (`OnOff` in App.swift: SwiftUI Toggle .switch, large, AX label + id `talk-mode`, `auto`, `space-mode`). LANGUAGE, EARS, the WRITTEN DOWN BY line, MICROPHONE, PAUSE, NOISE LIMIT and SAY IT AGAIN left the window: the language is Voice to Text's own pill (GET 127.0.0.1:8865/status `language`: en, hr or auto, read before every utterance and sent as /hear?lang=), the engine is Voice to Text's; the menu bar's TALK menu has Microphone, Pause, Noise limit, Space Mode, Auto, Engines… (the ENGINES panel kept, for Voice to Text's language; AUTO = its Croatian engine, as Voice to Text does).
- SPACE MODE (app/SpaceMode.swift): the mouse and the banner are Macro Recorder (Mantra) v28's ONE input lock (POST 127.0.0.1:8829/lock {owner talkmode-space, keys pass, plain_bar, blob false, esc_hold 2, beat 5}); the bar at the bottom of every screen reads "SPACE MODE — keyboard and mouse are off · SPACE talks · say “space mode off” or press TAKE OVER" with its TAKE OVER. The keyboard is Talk Mode's own active tap at the HID level (before every session tap): every key swallowed; Space without ⌘⌃⌥ = the first press starts a take, the second sends (as MANUAL Space, wherever the focus is); Macro Recorder's own events (MACRO_MARK) pass. Ways out: TAKE OVER; Escape held 2 s; the voice (SpaceExit: "space mode off", "exit space mode", "go out of this mode", "I want my keyboard back", "izađi iz space moda", "vrati mi tipkovnicu"; short sentences only, "talk mode off" stays typing mode; rules, no paid API); the switch; `talkmode://space-off`; quitting. Watchdog: Talk Mode beats POST /beat every second from its main thread; Macro Recorder (a separate process) lifts the lock when the beat stops for 5 s or Talk Mode's pid is gone; Talk Mode's tap lives on the main run loop, so a hang makes macOS switch it off (tapDisabledByTimeout); Macro Recorder not answering 3 beats = Space Mode off. Never on at start.
- Test: `open -g talkmode://space-test` = Space Mode for 10 s, then off by itself.
- Needs: Accessibility for Talk Mode (the keyboard tap); PERMISSIONS amber top right while missing (opens the Settings page); Macro Recorder v28 running.

**v5, 15.11.2026: speed and quality in the engine name (Marko: "how good is each engine and how fast is each engine in the engine name everywhere").** Voice to Text v24's `/hear` answer names the engine with its median time and stars, so the HEARD line reads "WRITTEN DOWN BY  Deepgram EN · 1.0 s · ★★★★☆ · now 1.3 s · Frankfurt · ...". A new cell EARS · TIME · QUALITY in the window (id `ears`) and the Language submenu of the menu bar show the engine picked for the language with the same tag, read from `GET /engines` (`label`, `label_hr`) every 20 s and after every utterance; the engine of each language comes from Voice to Text's preferences `engine_en` / `engine_hr`. Against Voice to Text before v24 the labels are plain names.

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
| Sessions.swift | v4: the sessions in a folder per DEVICE, newest activity first (MacBook Pro, chromium-vm, Nothing Phone, Pixel 7, Cloud), delivery per kind |
| ITerm.swift | iTerm2 AppleScript: list sessions (id, name, tty), `write text … newline NO`, 0.6 s, Return |
| Updater.swift | MANTRA_MANIFEST kits/mac-updater, repo TALK_MODE |

- **v4 (15.11.2026), the ears are Voice to Text's.** Every utterance goes to Voice to Text (Mantra) v23+'s local API,
  `POST 127.0.0.1:8865/hear?lang=en|hr` (WAV body): the engine Marko picked there for that language, its route (Frankfurt
  relay, key ring, retries) and corrections. The HEARD line shows "WRITTEN DOWN BY Deepgram EN · Frankfurt · 1.1 s".
  Voice to Text not running: its own binary `--hear <engine from its settings> <wav> <lang>`; not installed: MANTRA_VOICE
  /hear, said on that line. The voice that answers stays MANTRA_VOICE / Voice Engine.
- **v4, sessions by device** (① TALK TO, and the menu bar's Talk To): a folder per device, folders ordered by their newest
  session, sessions inside by last activity ("active 2 min ago"):
  MacBook Pro = iTerm2 tabs whose tty runs a Claude Code process (`~/.claude/sessions/<pid>.json`: name, folder, busy/idle;
  activity = the transcript's last change), typed with iTerm2 `write text`. chromium-vm = its tmux sessions
  (`ssh chromium-vm tmux list-panes -a`, activity = tmux session_activity), typed with `tmux send-keys -l` then Enter.
  Nothing Phone / Pixel 7 = adb over Tailscale: a `claude` process in Termux is shown GREYED: it runs without tmux, and adb
  `input` would type into whatever app is on the phone's screen (no Termux sshd either). Cloud = claude.ai/code sessions
  that wrote to the hub INBOX in the last two days, GREYED ("can't be typed into from here"). Offline devices say so.
  The choice is remembered (kind:id, then the name); the default is the newest Mac session named mac23…
- **v6, SEND NOW and Space** (15.11.2026): the SEND NOW button ends the sentence being heard and sends it at once. While
  the window is in front, Space starts a take (RECORDING…, the voice stops if it talks) and the second Space sends it
  (SENDING). A local key monitor: Space never reaches or leaves for another app.
- **v7, AUTO | MANUAL** (saved; the big word above the state, the SENDS cell, the menu): AUTO sends after the pause as
  before; MANUAL sends nothing by itself (the state reads PRESS SPACE). The global ⌃⌥T is gone (Marko: not needed).
- **v8, ENGINES** (CHANGE in the EARS cell, or the menu): every Voice to Text engine for the language, big rows with time,
  stars, quality %, credit (keys, free audio left in its window, trial credit or paid per hour, from Voice to Text's own
  records, nothing asked online) and route; BEST | STARS | TIME; a click or ↑ ↓ + Return makes it Voice to Text's engine
  for that language (POST 127.0.0.1:8865/engines/select, Voice to Text v26+), Esc closes.
- **v10, the archive** (Marko: "the same we are using on my phones ... AAC tiny files ... You never store the original WAV"): the mic is taken at its own quality (48 kHz float), made 16 kHz mono in memory for the engines (no WAV on disk), and each take is archived only as `~/Library/Application Support/Talk Mode (Mantra)/takes/<time>.m4a`, AAC mono 32 kbit/s like TTT's MaEncoder, newest 50; state.json `last_take`. v9 kept WAVs for one build; v10 deletes them.
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
  down, and only to catch the switch phrase; nothing is sent. Also the menu bar item, ③ (the global ⌃⌥T was removed in v7 at Marko's word), and
  `open -g talkmode://on|off|toggle|repeat|show`. The voice confirms: "Talk mode on. I am listening." / "Typing mode."
- **Repeat.** "say that again", "repeat that", "what did you say" … → `POST /speak/replay` (every reading since his last
  words). Each sent utterance first calls `/speak/seen`, so the replay is the answer to his last words.
- **For sessions.** `~/Library/Application Support/Talk Mode (Mantra)/state.json`: on, state, target, mic, lang, heard.

## Debug path (no microphone permission, no window)

    B="/Applications/Talk Mode (Mantra).app/Contents/MacOS/TalkMode"
    "$B" --list-sessions            # every device folder and its sessions (id, activity, why greyed); the default
    "$B" --deliver vm:talkmode_test "text"      # one delivery by id (or --deliver - --to-tty /dev/ttysNNN "text")
    "$B" --list-mics                # * = the one it would use
    "$B" --test-wav clip.wav (--to-tty /dev/ttys005 | --to <id>) [--lang en] [--pause 1.3] [--fast] [--mantra-voice]

    "$B" --preview thinking --shot /tmp/x.png [--size 720x500]   # the window drawn off screen into a picture
                                    # states: listening hearing writing thinking speaking typing recording down

The WAV is fed in real time (100 ms chunks) through the same Gate, detector, `/hear`, phrases and iTerm2 writer; one
JSON line per step (`loaded`, `voice`, `utterance`, `heard`, `sent`, `gate-closed`, `done`). Run it from an iTerm2 tab:
iTerm2 talking to itself needs no Automation permission. Target a throwaway tab running `cat`, never a real session.

## Proven 15.11.2026 (v2/v3, debug path)

`say` sentence + a 0.2 s click + "Say that again." in one WAV: voice at 2.0 s, utterance 3.6 s, written down word for
word, delivered to a throwaway iTerm2 window running `cat -u` (echoed back, so Return arrived); the click ignored as noise;
"Say that again." recognised as the repeat phrase. With a reading playing on BlackHole: gate closed for 14.7 s, 147 of 158
chunks dropped, nothing heard, nothing sent. Window drawn off screen at 1100×720 and 720×500: one title, nothing cut.
Not yet: the live microphone (needs Marko's Microphone permission) and the first send by the app itself (Automation).

## Proven 15.11.2026 (v4)

`--list-sessions`: MacBook Pro 2 sessions, chromium-vm 2 tmux sessions, Nothing and Pixel online with their Termux
`claude` greyed, Cloud 2 greyed, in 0.8 s. The WAV road through Voice to Text v23 (Deepgram EN via Frankfurt, 0.9 s)
delivered "Hello, Claude. This is a test of talk mode. Can you hear me?" into a throwaway tmux session `talkmode_test`
running `cat` on chromium-vm and into a throwaway iTerm2 `cat` window; quotes and `$` arrive unchanged over ssh. Both
throwaway targets removed afterwards. Not tested: the binary fallback end to end (its output format was checked), the
live microphone, the nested menu by hand.

## Install (nothing compiles on the Mac)

    gh release download --repo markoboskoauroville/TALK_MODE --pattern app.zip -D /tmp/tm --clobber
    ditto -x -k /tmp/tm/app.zip /Applications && codesign --force -s "Mantra Apps" "/Applications/Talk Mode (Mantra).app"

From v2 on, the app asks at start ("Do you want to update?").

## Permissions (Marko allows them, never answered for him)

1. **Microphone** at the first start (the ears open at once, also in typing mode, for the switch phrase).
2. **Automation → iTerm2** at the first session list or the first sentence sent.
3. **Accessibility** (v11) for SPACE MODE's keyboard tap: asked when the switch is first turned on.

## Icon

TAL / MOD over Claude's icon, "Claude and voice" orange (icon/README.md). Star row `talkmode` in STAR_SWIFT rows.json.
