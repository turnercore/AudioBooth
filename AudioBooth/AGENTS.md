# AudioBooth App Agent Guide

## Purpose

Xcode project containing the iOS app, watch app, widgets, app intents, UI screens, playback, download, storage, watch connectivity, and signing-sensitive app configuration.

## Ownership

- Own files under `AudioBooth/`.
- `AudioBooth/AudioBooth.xcodeproj` is the primary project.
- App group, entitlements, widgets, watch app, CarPlay, and local signing all converge here.

## Local Contracts

- Treat auth, watch sync, downloads, SwiftData, and app-group files as high-risk paths.
- Do not persist auth tokens or custom secret headers in plaintext storage unless an existing platform constraint forces it and the risk is documented.
- Keep expensive filesystem and SwiftData work off the main actor where possible.
- Do not commit `AudioBooth/Local.xcconfig`.
- Be careful with entitlements: personal-branch signing changes are allowed, but do not assume they are appropriate for upstream main.

## Work Guidance

- For playback changes, inspect `PlayerManager`, `BookPlayerModel`, `SessionManager`, widgets, and watch sync call sites before editing.
- For downloads/offline changes, inspect `DownloadManager`, `StorageManager`, local SwiftData models, and app-group paths together.
- For auth/server changes, inspect API services, OIDC flow, custom headers, watch connectivity, and logging together.
- For UI changes, follow existing SwiftUI view/model structure and avoid broad restyling.

## Verification

- Use `xcodebuild -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO` for broad compile validation.
- Simulator testing may depend on local CoreSimulator/Xcode health.
- Test watch/widget behavior when changing watch connectivity, app groups, timelines, or shared defaults.

## Child DOX Index

