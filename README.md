# Super Shout 📣

System-wide voice dictation for macOS, modeled on Wispr Flow but native, on-device, private, and free.

- Hold **fn** (or Right ⌘ / Right ⌥) → speak → release → clean text is inserted at the cursor in any app.
- Quick-tap the hotkey for hands-free mode; tap again to finish.
- On-device transcription (Apple Speech, `requiresOnDeviceRecognition`), automatic punctuation, filler-word removal, personal dictionary.
- **Smart joining** (`ContextReader` + `SpacingEngine`): reads the character before the caret over the Accessibility API, then adds the right space, capitalizes after `.?!`, and lowercases a mid-sentence continuation.
- **Auto-punctuation and list formatting** (`CleanupEngine` / `ListFormatter`): appends a period when missing; "I need eggs, milk, and bread" becomes a bulleted list (3+ items plus a cue word).
- **Learning** (`LearningEngine` + Fix Last Transcript, ⌘E): word-level LCS diff between what it heard and your correction yields dictionary entries and vocabulary terms. Vocabulary is fed to `SFSpeechAudioBufferRecognitionRequest.contextualStrings` so terms like UPC/ASIN are recognized correctly up front.
- **Entity smarts** (`EntityCorrector`): near-miss vehicle/product names snap to the real ones — "2019 Genesis G7" → "Genesis G70", "CX 5" → "CX-5", "F150" → "F-150". Only rewrites when exactly one valid model matches (exact, unique prefix, or one edit away); ambiguity never guesses.
- **Context-aware output**: search fields (detected via AX role/subrole) get no terminal period and no list formatting; terminal apps get literal text. Esc cancels a live dictation (swallowed by the event tap). "Undo Last Insertion" backspaces the last paste away.
- **Long dictation**: recognition tasks rotate every 50 s and segments are stitched, sidestepping SFSpeechRecognizer's ~1-minute limit.
- **Quality of life**: onboarding permission checklist window, launch-at-login toggle, persisted transcript history, words-dictated counter in the menu, fn/🌐 conflict warning, API key in the Keychain.
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
