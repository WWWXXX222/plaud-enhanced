# Third-party components

- Argmax `argmax-oss-swift`, commit `9f99b5cb6a907730543823ad271b82532782a899`.
  Sources are vendored under `offline-worker/Vendor/argmax-oss-swift` with LICENSE and NOTICES preserved.
- Swift Argument Parser: resolved by Swift Package Manager. See Package.resolved and its upstream license.
- Whisper model: `argmaxinc/whisperkit-coreml`, revision `0f63a7800b00dd0226abd051b906c246e1907482`,
  variant `openai_whisper-large-v3-v20240930_626MB`. Model and tokenizer provenance/hashes
  are saved in the downloaded model's manifest. The upstream OpenAI Whisper license
  is included in release packages under Resources/Whisper-LICENSE.
- FFmpeg, Python, Codex CLI, Claude Code and the optional Plaud CLI are installed
  separately by the user and retain their respective licenses and service terms.

No third-party accounts or credentials are distributed.
