# AudioBooth App Agent Guide

## Purpose

Xcode project containing the iOS app, watch app, widgets, app intents, UI screens, playback, download, storage, watch connectivity, and signing-sensitive app configuration.

## Ownership

- Own files under `AudioBooth/`.
- `AudioBooth/AudioBooth.xcodeproj` is the primary project.
- App group, entitlements, widgets, watch app, CarPlay, and local signing all converge here.

## Local Contracts

- Treat auth, watch sync, downloads, SwiftData, and app-group files as high-risk paths.
- Keep queued and retryable downloads represented by persisted `DownloadRequest` records; URLSession task descriptions identify relative app-group paths and must not contain credentials.
- Reconcile downloaded audiobook track offsets and duration from the local assets before local playback; server estimates must not leave offline progress on a different timeline.
- Resuming after a completed sleep timer clears it without implicitly extending or auto-rearming it; extension remains an explicit alert or shake action.
- Do not persist auth tokens or custom secret headers in plaintext storage unless an existing platform constraint forces it and the risk is documented.
- Watch audiobook bootstrap uses bounded public media shares created and revoked by the authenticated iPhone. Send only the public hostname/base path, share identity/expiry, and expected local-manifest tracks; phone relay remains a fallback.
- Keep expensive filesystem and SwiftData work off the main actor where possible.
- Do not commit `AudioBooth/Local.xcconfig`.
- Preserve the personal app identifiers, `group.com.turnercore.audioBS` app-group setup, and intentionally absent CarPlay entitlement unless the user explicitly requests a signing or capability change.
- In-app purchases and the Tip Jar are intentionally removed from `personal-main`. Do not restore StoreKit configuration, RevenueCat dependencies or startup code, Tip Jar views/models, or settings links when resolving upstream merges.
- Treat personal AirPlay and playback-route behavior as an intentional merge-sensitive delta. Review `PlayerManager`, `BookPlayerModel`, `SessionManager`, and the personal-only commit history before accepting upstream playback changes.
- Treat `AVPlayerItem.failedToPlayToEndTimeNotification` as terminal for that item: preserve play intent, rebuild the queue/session, and keep playback diagnostics free of URLs, session IDs, headers, and tokens.
- Personal-branch signing and product changes are not assumed to be appropriate for upstream main.

## Work Guidance

- For playback changes, inspect `PlayerManager`, `BookPlayerModel`, `SessionManager`, widgets, and watch sync call sites before editing.
- For downloads/offline changes, inspect `DownloadManager`, `DownloadRequest`, `StorageManager`, local media models, and app-group paths together; verify foreground/network resume and background task reattachment.
- For auth/server changes, inspect API services, OIDC flow, custom headers, watch connectivity, and logging together.
- For UI changes, follow existing SwiftUI view/model structure and avoid broad restyling.
- For library search changes, preserve server matches and use cached filter data only as a conservative fuzzy fallback.
- Keep Home personalized-shelf loading independent from user progress synchronization so one failure cannot leave all shelves stale.
- Keep remote cover failures visible in persistent logs; cached covers can otherwise hide active image-networking failures.
- Home requests up to 20 personalized items per shelf, including the API's expanded Recent Series result.

## Verification

- Use `xcodebuild -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO` for broad compile validation.
- Use the `AudioBoothTests` target through the shared `AudioBooth` scheme for focused iOS unit tests; `build-for-testing` against `generic/platform=iOS` provides a device-independent compile check.
- Simulator testing may depend on local CoreSimulator/Xcode health.
- Test watch/widget behavior when changing watch connectivity, app groups, timelines, or shared defaults.

## Child DOX Index
