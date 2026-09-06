# Changelog

## 0.5.1 — 2026-09-06

- Capture Bluetooth microphone audio in its native format and convert it inside the app; release input after recording when Bluetooth warming is disabled.
- Honor the selected Bluetooth recording input independently of idle warming.
- Wait for input samples before Listening, clean up canceled/timed-out startup and retain interrupted results for review.
- Keep empty transcription responses in recovery with an explanation instead of reporting Ready or inserting empty text.
- Preserve isolated Review configuration across launches and make the Review identity visible.
- Use a 44×24-point translucent idle pill with background-click and automatic collapse, retained result/error indicators and reduced idle Dock polling.
- Only the compact idle pill is translucent; controls, recovery and call offers use opaque surfaces. Meter history updates at 10 Hz with gentle attack/release smoothing.
- Surface call offers over retained result/error status and diagnose placement failures without logging field content.
- Include native CoreMedia conversion regression coverage alongside 91 Swift tests and 289 assertions.

## 0.5.0 — 2026-09-06

Released capture ownership, durable recovery, destination validation and native client interface improvements.
