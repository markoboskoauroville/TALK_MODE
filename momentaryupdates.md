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

## 15.11.2026, request 10 (v11): macOS switches everywhere, and SPACE MODE

"It is working. Talk mode. We need to update more app. ... I ask for a switch, typical switch in the Mac OS. A switch, a button, round button, looks like ellipse and inside is a small circle. So I want to have this kind of switch. I like these switches, I want to see them everywhere. and another switch will be which doesn't exist at the moment and that switch is space mode in parenthesis it means that basically my keyboard and mouse outputs are disabled completely you can also put this banner that is disabled and I press space and you do all the actions We are just interacting to the voice. So I can space reacts wherever is the focus. It triggers the recording and you are answering to me."

## 15.11.2026, request 11 (v11)

"Yes, that is correct, but you need to also put this blocking banner you are using when macro is running, so I can also press and take over. And I can also in voice tell you, okay, go out of this mode. You will understand how to get out of the space mode."

## 15.11.2026, request 12 (v11)

"in our app talk mode These are unnecessary parts, language, ears. I don't need these things. Because language is in my transcription blob. I can adjust everything and this is what is the default."

**Status:** saved first; built in v11.

## 15.11.2026, request 13 (v12): the window out of the screen, and "PAUSED · RECORDING"

"Please update the talk mode again. User interface is disaster. It going out of the screen and is just staying there. Please make it understand when I leave it somewhere that nothing is going out of the display. It needs to adjust its height and heights so I see the bottom of the thing. and especially in When I change monitors then so monitors a different size then it is falling out ... You are giving confusing messages in this talk mode. I am recording now, it says paused recording. What is paused? I am recording right now, there is no pause at all. It is recording. What is this paused?"

**Status:** saved first; built in v12.

## 15.11.2026, request 14 (v12): the red edge in Space Mode

"Space mode, please, when you do space mode, put the red edge, same as on Sony camera, we already have this summary manifest, when Sony camera records, there is a red around it, it means it's doing something special, and this thing is also something special, so put the red, half transparent, soft vignette, but not too soft, same as on Sony. Look at the Sony pictures on the internet and make me the same outline so I understand I'm in space mode."

**Status:** saved first; built in v12.

## 15.11.2026, request 15 (v13): HEARD must not linger

"and there is annoying text happening here in talk mode it says heard mother what's happening again where i am again where are you i don't know what is this this is so stupid"

**Status:** saved first; built in v13.

## 15.11.2026, request 16 (v13): a normal window

"This app has another annoying feature. It snaps to the top of the window, always. I cannot resize it. I want to make it small, it always jumps to the top. What is this? Please make it normal window. Edges are resizing it in all axis."

**Status:** saved first; built in v13.

## 15.11.2026, request 17 (v13): Whisper hallucinations on silence (from the coordinator, observed 15.11.2026)

While Marko was away, AUTO sent "I'm going to go to the bathroom." (twice), "I'm going to go ahead and start the game.", "I'm going to go get some coffee.": classic Whisper hallucinations on room noise. Guard: real speech energy for 0.6 s above the noise floor; drop known hallucination phrases and near-duplicates within 2 min; drop empty-ish / no_speech results; dropped ones shown briefly as "ignored (noise)" and logged, never sent.
