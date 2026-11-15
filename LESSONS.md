# Talk Mode (Mantra): LESSONS

- 15.11.2026: MANTRA_VOICE's MicGuard pauses the voice while a program that records a real microphone is "listening",
  but only programs named like "voice to text" or "speechify" count (voiced.py MicGuard.LISTENERS). A talk app keeps the
  microphone open all the time, so its name must stay out of that list, or Claude's answer would never be spoken.
- 15.11.2026: `/speak/replay` already reads every answer since Marko's last words (UNHEARD); calling `/speak/seen`
  before each sent sentence makes "say that again" the answer to the last question, no cache of our own.
- 15.11.2026: iTerm2: text and Return in one `write text` can land as a pasted line that Claude Code does not send; text
  with `newline NO`, 0.6 s, then an empty `write text` (ELEVATE_MEDIA_MONITOR embrain.py, proven 2.11.2026). `tab` is an
  iTerm2 class in AppleScript: the separator is `character id 9`, set outside the `tell`.
- 15.11.2026: the debug path (`--test-wav`) runs from an iTerm2 tab, so iTerm2 writes to itself: no Automation prompt
  and no microphone, and the whole road (gate, detector, Whisper, phrases, writer) is proven before Marko allows anything.
