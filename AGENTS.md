# AudioBooth Agent Guide

## DOX Rules

- `AGENTS.md` files are binding work contracts for their subtrees.
- Before editing, walk from the repository root to every target path and read every `AGENTS.md` found along the way.
- If docs conflict, the closer `AGENTS.md` controls local details, but no child may weaken root requirements.
- After meaningful changes, update the closest owning `AGENTS.md` when purpose, scope, ownership, workflows, commands, contracts, artifacts, or validation expectations change.
- Update parent docs when parent-level structure or child index entries change.
- Keep docs concise, operational, and current. Delete stale text instead of explaining history.

## Repository Rules

- This checkout is optimized for the owner's personal deployment and maintenance workflow. Build work on `personal-main`.
- Treat `personal-main` as a maintained product branch, not as a clean mirror of upstream.
- Use `upstream/main` as the source of upstream updates. Merge it into `personal-main` after reviewing incoming commits and the personal delta; rebase the published personal branch only when explicitly requested.
- Preserve intentional personal-branch differences during upstream syncs: removed monetization, personal signing and entitlements, stability/security hardening, package-boundary cleanup, and playback/AirPlay behavior that still differs from upstream.
- Resolve upstream conflicts semantically. Before accepting either side, inspect `git log upstream/main..personal-main` and the affected file history so an upstream edit does not silently restore a deliberately removed feature.
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
