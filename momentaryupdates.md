# Momentary updates: Marko's requests, word for word, before any code

## 15.11.2026, request 1 (v1)

"Please, we need to develop now real conversation mode. When I'm not typing and then you are responding. We are talking with each other. Can you develop this now? So when I say real time talk mode, you are waiting for me to pause, then you say something and we kind of do this thing together. please make something like this one swift application real-time chat or something like this give it a nice name so we can switch from this to that in the same chat because I'm not in front of computer I'm in front of the camera and I cannot remember everything you said so we need to talk"

## 15.11.2026, request 2 (v4)

"So, talk mode is there. It needs to use my engine basically, voice to text, the same one I'm using for transcription, and of course voice engine for talking. So, engines are in place. This is only logic that it stops and responds. and we can test it, but I want to have control inside the app to which open session I am talking to. So it needs to list all my open session by folders. Folders are meaning in which device is the session. So I open the devices and then I can talk to any of my sessions. That should be next update please."

## 15.11.2026, request 3 (v4)

"And of course the session are ordered by activity. So last active session is at the top"

## 15.11.2026: how good and how fast each engine is, in the engine name (via the master session)
Marko, 15.11.2026, word for word:
> Please now update how good is each engine and how fast is each engine in the engine name everywhere.

**Status:** saved first. Voice to Text v24 keeps per-engine median time (last 20 takes, per language) and a quality score (WER against a reference phrase in TEST mode, or Marko's rating) and shows "Deepgram · 1.0 s · ★★★★☆" wherever an engine name appears; Talk Mode v5 reads it from /engines.

## 15.11.2026, request 4 (v5)

"build button to send transcription now without waiting shortcut key if app is in focus is space for both star recording and transcribe"

## 15.11.2026, request 5 (v7)

"There should be also a switch, a switch which is like auto advanced mode or manual mode for this kind of chat."

## 15.11.2026, request 6 (v7)

"Yes, but this shortcut is not necessary because now we have mode Auto Advanced and Manual and we have spacebar. So there is no need for this."

## 15.11.2026, request 7 (v8; his message was cut off at the end)

"I want to have luxurious changing of engines, it's basically will be remote control for our VOX application, audio to text, but in this app, talk mode, I want to have this option, it means I have the stars ratings, timing and everything, and the credits and…"

## 15.11.2026, request 8 (v9, via the master session)

Keep the audio of each utterance it sends: ~/Library/Application Support/Talk Mode (Mantra)/takes/<timestamp>.wav (16 kHz mono, the last 20), its path in state.json as "last_wav", so one recorded sentence can be run through every Voice to Text engine.

## 15.11.2026, request 9 (v10)

"please use archive the same we are using on my phones. It's AAC tiny files. That's it. You never store the original WAV. So the same principle apply here. If it's not, I don't know. Record in full quality, 48 kHz, 24 bits, and then you need to compress it to tiny WAV file and convert it to AAC for even tinier file."
