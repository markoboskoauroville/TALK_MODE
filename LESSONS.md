# Talk Mode (Mantra): LESSONS

- 15.11.2026: MANTRA_VOICE's MicGuard pauses the voice while a program that records a real microphone is "listening",
  but only programs named like "voice to text" or "speechify" count (voiced.py MicGuard.LISTENERS). A talk app keeps the
  microphone open all the time, so its name must stay out of that list, or Claude's answer would never be spoken.
- 15.11.2026: `/speak/replay` already reads every answer since Marko's last words (UNHEARD); calling `/speak/seen`
  before each sent sentence makes "say that again" the answer to the last question, no cache of our own.
- 15.11.2026: iTerm2: text and Return in one `write text` can land as a pasted line that Claude Code does not send; text
  with `newline NO`, 0.6 s, then an empty `write text` (ELEVATE_MEDIA_MONITOR embrain.py, proven 2.11.2026). AppleScript
  names are case-blind: a separator `T` and the loop variable `t` (the tab) were one variable (error -1700 in v1);
  `tab` is also an iTerm2 class. Long names (`sepTab`, `aTab`, `aSes`) only.
- 15.11.2026: the debug path (`--test-wav`) runs from an iTerm2 tab, so iTerm2 writes to itself: no Automation prompt
  and no microphone, and the whole road (gate, detector, Whisper, phrases, writer) is proven before Marko allows anything.
- 15.11.2026 (v4): one SwiftUI expression holding the nested device Menu, its ForEach and the string building did not
  type-check in time on the runner ("unable to type-check this expression"); the picker became its own View with small
  helper functions, and it built.
- 15.11.2026 (v4): the phones' Claude Code runs as `proot → claude` in Termux, with no tmux and no sshd: there is no way
  to type into it from the Mac that cannot land in another app. Listed greyed with that reason until a tmux (or a socket)
  exists on the phone.

- 15.11.2026 (v11): Space Mode reuses Macro Recorder's lock instead of a second banner, but the lock as it was (v27) would
  have recorded and replayed every Space at the end, cut a long sentence at 420 pt, and left the GIVE THE MAC BACK blob
  (which refuses Claude's macro runs) after TAKE OVER. Macro Recorder v28 grew options for a holder that owns the keyboard
  (keys pass, plain bar, no blob, esc_hold, a beat watchdog) rather than Talk Mode drawing its own bar.
- 15.11.2026 (v11): the keyboard tap sits at the HID level, before Macro Recorder's session tap, and on the main run loop:
  a frozen Talk Mode cannot hold the keyboard (macOS disables a tap that does not answer), and its frozen main thread stops
  the beats, so Macro Recorder lifts the mouse lock within 5 s.

- 15.11.2026 (v12): "PAUSED · RECORDING" was the state while Voice to Text's recording.flag/take-open was alive: Talk Mode was
  waiting, not recording, and the word said the opposite of what Marko felt. A state word must say who does what, from his
  side: RECORDING… is his take in Talk Mode, "VOX IS RECORDING — I WAIT" is another recorder holding the microphone.
- 15.11.2026 (v12): setFrameAutosaveName restores a frame that no longer fits a different monitor; the frame is now stored per
  screen configuration and always passed through WindowFit (shrink, then move inside) after every move, screen change and wake.
- 15.11.2026 (v13): custom window code (v12 WindowFit: fit after every move, remembered frames) made it worse: Marko could not
  shrink it and it jumped. Standard NSWindow + frame autosave + AppKit's constrainFrameRect, nothing invented. NSHostingView's
  default sizingOptions also set the window's minimum from the content: sizingOptions = [] keeps it a normal resizable window.
- 15.11.2026 (v13): HEARD cleared 6 s after sending (fade), so an old mis-heard sentence never stays.

- 16.11.2026 (v16): the big word must say what the microphone does, in one word, from his side: red = his voice is being recorded (RECORDING), waiting with an open mic is LISTENING. A status shown only in the window is lost when the app is in the background (Space Bar Mode): the menu bar item with the same word and the VU meter is always there. A full-screen red frame covered the menu bar: the indicator is a strip along the bottom only.

## Lesson: hover card and pipes (16.11.2026)
Poll the mouse (macOS draws a status item once per display, only one copy owns the button, so a tracking area misses the other display). The panel needs `titleVisibility = .hidden` for the one-title guard. A non-activating NSPanel at statusBar+1 never takes focus. Pipes for text items: attributed title; for icon items: pipedIcon + rightPipe; for view items: drawPipes or PipesView.
