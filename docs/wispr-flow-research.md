# Wispr Flow — Competitive Analysis (research basis for Super Shout)

## Overview
Wispr Flow (wisprflow.ai) is a system-wide AI voice dictation app for Mac, Windows, iPhone, and Android. Press a hotkey anywhere, speak naturally, and it inserts cleaned, formatted text at the cursor. Core pitch: "speak naturally, get polished writing" — auto-edits (filler removal, grammar, punctuation, list formatting) in one pass. Claims 4x faster than typing. G2 4.5/5 but Trustpilot 2.7/5.

## Activation & Insertion UX
- Default hotkey: hold Fn on Mac (push-to-talk). Double-tap for hands-free open-mic mode.
- Flow Bar: floating pill showing recording state + waveform feedback.
- Insertion: simulated paste at cursor via accessibility APIs; ~1s after key release.
- Latency: claimed <700ms p99; users report 1-2s real-world, plus 8-10s cold start.

## Features
- AI auto-edits (fillers, punctuation, grammar, formatting) — no voice commands needed.
- Context/tone awareness per app (casual Slack vs formal email) — historically via periodic screenshots (see weaknesses).
- Personal dictionary (auto-learned + manual), snippets, Command Mode (Pro), Whisper Mode, 100+ languages.
- Teams/Enterprise: SSO/SAML, enforced privacy mode, SOC 2 II, ISO 27001, HIPAA.

## Pricing
- Free: 2,000 words/week desktop. Pro: $15/mo ($12 annual), unlimited. Enterprise: custom.

## Tech / Privacy
- Cloud-only: all audio goes to Wispr's cloud. No offline mode.
- 2025 screenshot scandal: app captured active-window screenshots every few seconds for "context"; went viral on Reddit; became opt-in only after backlash.
- Electron client: ~800MB RAM, ~8% CPU idle, 8-10s startup.

## Weaknesses
1. No offline mode. 2. Privacy trust deficit. 3. Resource hog. 4. Post-trial reliability complaints (Trustpilot 2.7). 5. Weak Windows build. 6. Subscription fatigue vs one-time competitors. 7. Weak markdown/math/power controls. 8. ~90% accuracy ceiling; AI sometimes over-edits meaning.

## Competitors
- Superwhisper: on-device Whisper, $249.99 lifetime, Mac-only, power-user config.
- MacWhisper: €59 lifetime, local, mostly file transcription.
- Aqua Voice: cloud, dev-focused, ~450ms claims.
- Willow: hybrid local/cloud, positions directly against Wispr on latency/privacy.
- Native macOS dictation: free/on-device but no AI cleanup.

## How Super Shout wins
1. Local-first on-device ASR (offline, private, <300ms). 2. Native Swift, ~20MB RAM. 3. No screenshots ever. 4. Free (no per-word cloud cost). 5. Copy the loved UX: hold-Fn, quick-tap hands-free, floating bar with waveform, insert-at-cursor, dictionary. 6. Optional Claude polish with user's own key, off by default.
