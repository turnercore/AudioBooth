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
- Preserve the personal app identifiers, `group.com.turnercore.audioBS` app-group setup, and intentionally absent CarPlay entitlement unless the user explicitly requests a signing or capability change.
- In-app purchases and the Tip Jar are intentionally removed from `personal-main`. Do not restore StoreKit configuration, RevenueCat dependencies or startup code, Tip Jar views/models, or settings links when resolving upstream merges.
- Treat personal AirPlay and playback-route behavior as an intentional merge-sensitive delta. Review `PlayerManager`, `BookPlayerModel`, `SessionManager`, and the personal-only commit history before accepting upstream playback changes.
- Treat `AVPlayerItem.failedToPlayToEndTimeNotification` as terminal for that item: preserve play intent, rebuild the queue/session, and keep playback diagnostics free of URLs, session IDs, headers, and tokens.
- Personal-branch signing and product changes are not assumed to be appropriate for upstream main.

## Work Guidance

- For playback changes, inspect `PlayerManager`, `BookPlayerModel`, `SessionManager`, widgets, and watch sync call sites before editing.
- For downloads/offline changes, inspect `DownloadManager`, `StorageManager`, local SwiftData models, and app-group paths together.
- For auth/server changes, inspect API services, OIDC flow, custom headers, watch connectivity, and logging together.
- For UI changes, follow existing SwiftUI view/model structure and avoid broad restyling.

## Verification

- Use `xcodebuild -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO` for broad compile validation.
- Use the `AudioBoothTests` target through the shared `AudioBooth` scheme for focused iOS unit tests; `build-for-testing` against `generic/platform=iOS` provides a device-independent compile check.
- Simulator testing may depend on local CoreSimulator/Xcode health.
- Test watch/widget behavior when changing watch connectivity, app groups, timelines, or shared defaults.

## Child DOX Index
