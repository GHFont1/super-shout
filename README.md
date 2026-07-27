# Super Shout 📣

System-wide voice dictation for macOS, modeled on Wispr Flow but native, on-device, private, and free.

- Hold **fn** (or Right ⌘ / Right ⌥) → speak → release → clean text is inserted at the cursor in any app.
- Quick-tap the hotkey for hands-free mode; tap again to finish.
- On-device transcription (Apple Speech, `requiresOnDeviceRecognition`), automatic punctuation, filler-word removal, personal dictionary.
- Floating "Shout Bar" HUD with live waveform + partial transcript.
- Optional Claude API polish (off by default, user-supplied key, model selectable in Settings).

## Layout

- `app/` — SwiftPM package. `./build-app.sh [--install]` builds `SuperShout.app` (ad-hoc signed) and optionally installs to `/Applications/Super Shout.app`.
- `site/` — static marketing site (deployed to Netlify) with a downloadable zip of the app.
- `docs/wispr-flow-research.md` — competitive analysis that drove the design.

## Permissions required (one-time)

Microphone, Speech Recognition, and Accessibility (for the global hotkey listener and synthetic ⌘V paste). The app prompts on first launch.

## How insertion works

Clipboard swap: saves current pasteboard, writes the transcript, posts ⌘V via CGEvent, restores the pasteboard ~0.5 s later.
