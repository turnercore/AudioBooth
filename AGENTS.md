# AudioBooth Agent Guide

## DOX Rules

- `AGENTS.md` files are binding work contracts for their subtrees.
- Before editing, walk from the repository root to every target path and read every `AGENTS.md` found along the way.
- If docs conflict, the closer `AGENTS.md` controls local details, but no child may weaken root requirements.
- After meaningful changes, update the closest owning `AGENTS.md` when purpose, scope, ownership, workflows, commands, contracts, artifacts, or validation expectations change.
- Update parent docs when parent-level structure or child index entries change.
- Keep docs concise, operational, and current. Delete stale text instead of explaining history.

## Repository Rules

- This checkout is for the personal branch workflow. Build work on `personal-main`.
- It is allowed to merge or rebase from upstream `main` into `personal-main` to stay current.
- Do not merge `personal-main` into upstream `main` from this repo unless the user explicitly asks for that.
- Always commit finished repo changes.
- Use Swift 6.2 and the existing SwiftUI/ViewModel patterns.
- Keep changes focused and boring; prefer existing helpers and local patterns over new abstractions.
- Use Context7 for current documentation of languages, Apple APIs, or game engines when needed.
- Use the in-app browser for browser-based testing; use Playwright only if the in-app browser fails.
- Local host Python may not have `pytest`; check for a venv before Python test work.
- Do not commit local signing files such as `AudioBooth/Local.xcconfig`.

## Verification

- Format Swift with `xcrun swift-format format --in-place --recursive --parallel .` when editing Swift.
- Lint Swift with `xcrun swift-format lint --strict --recursive --parallel .` when practical.
- Build the app with `xcodebuild -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO` for broad validation.
- Plain `swift test` currently does not provide a reliable baseline because the local packages are iOS/watchOS-oriented and SwiftPM attempts a macOS build.

## Child DOX Index

- `API/AGENTS.md` - Audiobookshelf API client, networking, auth, DTOs, and API package dependencies.
- `Models/AGENTS.md` - SwiftData/local persistence models and model package contracts.
- `PlayerIntents/AGENTS.md` - App Intents package for playback/system integrations.
- `AudioBooth/AGENTS.md` - Xcode app project, iOS/watch/widgets, managers, UI, and signing-sensitive targets.
