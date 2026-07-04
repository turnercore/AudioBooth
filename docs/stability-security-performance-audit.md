# AudioBooth Stability, Security, and Performance Audit

Date: 2026-07-04
Branch: `audit/stability-security-performance`

This report combines local review with four `gpt-5.4-mini` exploratory agents:

- Concurrency and UI hangs
- Networking, auth, and security
- Persistence, downloads, and file integrity
- Performance and lifecycle risks

## Verification

- `xcodebuild -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO` succeeded.
- `xcodebuild -list -project AudioBooth/AudioBooth.xcodeproj` succeeded, but the host reports a CoreSimulator mismatch: current CoreSimulator `1051.54.0`, Xcode expects `1051.55.0`.
- `swift test` in `API`, `Models`, and `PlayerIntents` fails before test execution because SwiftPM tries a macOS build while the package manifests only declare iOS/watchOS platforms and dependencies require macOS 11-13.

## Highest Priority Findings

### 1. Storage cleanup runs expensive file and SwiftData work on the main actor

Severity: High

Evidence:

- `AudioBooth/AudioBooth/AppDelegate.swift:70-73` starts launch cleanup inside `Task { @MainActor in ... }`.
- `AudioBooth/AudioBooth/Services/StorageManager.swift:71-110` marks `cleanupUnusedDownloads()` as `@MainActor`, fetches all local books, then fetches `MediaProgress` per downloaded book and may delete downloads from that path.
- `AudioBooth/AudioBooth/Screens/Settings/StoragePreferences/StoragePreferencesViewModel.swift` also drives storage cleanup and storage breakdown work from the storage UI.

Impact:

Large libraries can hitch launch and the Storage screen because database fetches, filesystem traversal, and deletion are serialized through the UI actor. The N+1 `MediaProgress` fetch inside the book loop amplifies that cost.

Minimal fix:

Move filesystem enumeration/deletion and derived cleanup selection off the main actor. Use `MainActor` only to read UI-only state and publish final results. Preload progress into a `bookID -> MediaProgress` lookup before iterating books.

### 2. OIDC/auth logs can persist secrets

Severity: High

Evidence:

- `AudioBooth/AudioBooth/Screens/Servers/Server/OIDCAuthenticationManager.swift:53-65` logs the callback URL and raw query parameters, including authorization codes.
- `AudioBooth/AudioBooth/Screens/Servers/Server/OIDCAuthenticationManager.swift:131-134` logs PKCE challenge data.
- `AudioBooth/AudioBooth/Screens/Servers/Server/OIDCAuthenticationManager.swift:182-195` logs auth endpoint response bodies.
- `API/Sources/API/Services/AuthenticationService.swift:141` logs the raw Cookie header.
- `AudioBooth/AudioBooth/Services/AppLogger.swift:25-28` persists debug logs through Pulse.

Impact:

OIDC authorization codes, cookies, state values, and auth endpoint payloads can land in persistent logs. Existing network redaction helps for structured Pulse network events, but these are ordinary app log messages.

Minimal fix:

Stop logging raw auth URLs, query values, cookies, PKCE material, and auth response bodies. Log only event names, status codes, counts, and lengths. Add redaction for `code`, `code_verifier`, `state`, `Cookie`, `Authorization`, `x-refresh-token`, `token`, `accessToken`, and `refreshToken` in general app log messages if logs stay at debug.

### 3. Shared connection links can export raw credentials

Severity: High

Evidence:

- `AudioBooth/AudioBooth/Screens/Servers/Server/ConnectionSharingPageViewModel.swift:29-39` regenerates a deep link and QR code with `includeCredentials`.
- `AudioBooth/AudioBooth/Services/DeepLinkManager.swift:91-102` base64-encodes the exported connection into an `audiobooth://connection/...` URL.
- `AudioBooth/AudioBooth/Services/DeepLinkManager.swift:130-135` includes refresh tokens or API keys when credential sharing is enabled.
- `AudioBooth/AudioBooth/Services/DeepLinkManager.swift:120-123` also includes custom headers.

Impact:

Anyone who sees or receives the share URL or QR code can recover long-lived credentials and custom headers.

Minimal fix:

Default to credential-free sharing. If credential sharing remains, make the UI treat it as a secret export and prefer short-lived server-issued share tokens over embedding refresh tokens/API keys.

### 4. SwiftData save failures are swallowed after files are written

Severity: Medium-High

Evidence:

- `AudioBooth/AudioBooth/Services/DownloadManager.swift:462`, `491`, `547`, and `572` use `try?` when saving downloaded local metadata.
- `Models/Sources/Models/LocalBook.swift:141-177`, `Models/Sources/Models/LocalEpisode.swift:91-117`, and similar model helpers declare `throws` but call `try? context.save()`.

Impact:

Downloads can complete on disk while SwiftData metadata silently fails to persist. The UI and storage cleanup code can then disagree about what is downloaded.

Minimal fix:

Make model save/delete helpers actually throw `context.save()` failures. Let download operations fail if metadata cannot be committed.

### 5. Download finalization can remove a valid previous file before replacement succeeds

Severity: Medium

Evidence:

- `AudioBooth/AudioBooth/Services/DownloadManager.swift:762-771` removes an existing destination before moving the new temporary download into place.
- `AudioBooth/AudioBooth/Services/DownloadManager.swift:820-839` accepts any 2xx download without validating byte count against the expected size.

Impact:

If the move fails after removal, the previous good copy is lost. If a server returns truncated content with a 2xx response, the app can mark a bad payload complete.

Minimal fix:

Move to a staging path and atomically replace the destination. Check final file size against expected size where the API provides it.

## Additional Findings

### Bookmark sync and token refresh are over-pinned to `@MainActor`

Evidence:

- `API/Sources/API/CredentialsActor.swift:47-49` creates `Task<Credentials, Error> { @MainActor ... refreshToken(...) }`.
- `AudioBooth/AudioBooth/Services/BookmarkSyncQueue.swift:87-89`, `106-127`, and `137-144` run bookmark network sync work in `Task { @MainActor in ... }`.

Correction to the attached UI-hang note:

An awaited URLSession request on the main actor does not normally busy-block the run loop for the full network duration. The real risk is main-actor serialization: request setup, post-await continuation, SwiftData saves, and all other main-actor work queue behind each other. It is still worth removing `@MainActor` from the network portions and hopping to `MainActor` only for SwiftData/UI state that requires it.

### Generic SwiftData observation is main-actor pinned

Evidence:

- `Models/Sources/Models/PersistentModel+Observations.swift:11-58` and `62-104` start observation tasks with `Task { @MainActor in ... }`.
- These helpers fetch data and loop on `ModelContext.didSave` notifications.

Impact:

Every subscriber pays a main-actor fetch cost and keeps a long-lived main-bound task. This affects offline list, book details, and continue-listening card flows.

Minimal fix:

Keep observation work as small as possible. Cancel observation tasks explicitly in view models and avoid repeated initial fetches. If moving off-main, use an isolated SwiftData context correctly rather than passing main-context models across actors.

### Repeated screen appearances can stack tasks and observers

Evidence:

- `AudioBooth/AudioBooth/Screens/BookDetails/BookDetailsView.swift` calls `model.onAppear()` from load/retry paths.
- `AudioBooth/AudioBooth/Screens/BookDetails/BookDetailsViewModel.swift` starts load tasks and replaces observation task handles without consistently cancelling the prior work first.
- Similar patterns were reported in podcast details and card models with long-lived observation tasks.

Impact:

Repeated appearances can duplicate observers, keep stale work alive, and allow old async results to race newer screen state.

Minimal fix:

Store the active load task, cancel it before starting a new one, and cancel existing observation handles before replacing them.

### Database recovery deletes local data on any container creation error

Evidence:

- `Models/Sources/Models/ModelContextProvider.swift:67-97` catches any `ModelContainer` creation error, removes the `.sqlite`, `-shm`, and `-wal` files, then retries with a fresh container.

Impact:

A transient startup or migration problem can wipe local metadata instead of preserving it for diagnosis or recovery.

Minimal fix:

Rename the old database files to a timestamped backup before recreating. Only destructive deletion should happen after confirming unrecoverable corruption.

### Plain HTTP is accepted for credentialed flows

Evidence:

- `API/Sources/API/Services/NetworkDiscoveryService.swift:67` probes local servers over HTTP.
- Server URL inputs and alternative URLs accept `http` in app flows.
- `API/Sources/API/NetworkService.swift` sends requests to the supplied URL verbatim.

Impact:

Self-hosted local HTTP may be intentional, but login, refresh, custom headers, and media tokens can travel over plaintext on hostile networks.

Minimal fix:

Keep HTTP discovery, but require explicit confirmation before saving or authenticating against HTTP. Prefer HTTPS for credentialed requests and visually mark insecure servers.

### Tokens are placed in URL query strings

Evidence:

- `AudioBooth/AudioBooth/Services/WatchConnectivityManager.swift` appends tokens as `?token=` for watch track URLs.
- `AudioBooth/AudioBooth/Screens/BookDetails/Components/EbooksContent/EbooksContentModel.swift` appends tokens as `?token=` for ebook URLs.

Impact:

Query-string tokens are more likely to leak through logs, caches, screenshots, and copied URLs than headers.

Minimal fix:

Prefer Authorization headers where the consumer supports them. Where a URL-only consumer forces query auth, mint short-lived URLs or scope tokens narrowly.

### `API` re-exports `NukeUI` into every API consumer

Evidence:

- `API/Sources/API/Audiobookshelf.swift:3` uses `@_exported import NukeUI`.
- `API/Package.swift:26` depends on `.product(name: "NukeUI", package: "Nuke")`.
- The `API` module itself configures `ImagePipeline`, `DataLoader`, and `DataCache`, which come from `Nuke`, while UI files that render `LazyImage` can import `NukeUI` directly.

Impact:

`API` is otherwise the Audiobookshelf client layer: auth, network requests, DTOs, sessions, libraries, and discovery. Re-exporting `NukeUI` means every module that imports `API` also inherits SwiftUI image-loading symbols and a UI dependency edge it may not use. That hides real dependencies in app/watch views and makes non-UI consumers pay for a convenience import.

Minimal fix:

Remove `@_exported import NukeUI` from `Audiobookshelf.swift`, keep `import Nuke`, and add explicit `import NukeUI` only to UI files that use `LazyImage`. Then change `API/Package.swift` to depend on the `Nuke` product instead of `NukeUI` if `API` only needs the image pipeline types.

## Suggested Fix Order

1. Remove raw OIDC/cookie/response-body auth logging.
2. Move storage cleanup selection and file deletion off the main actor.
3. Make local model persistence failures propagate out of download completion.
4. Make download finalization atomic and size-checked.
5. Tighten credential sharing and HTTP credential warnings.
6. Cancel duplicate view-model tasks and observation streams before replacement.
7. Stop re-exporting `NukeUI` from `API` and import it explicitly from UI files.

## Notes

- I did not find `DispatchQueue.main.sync` or explicit blocking sleeps in the core UI paths.
- The attached `CredentialsActor` and `BookmarkSyncQueue` concerns are valid as main-actor overuse, but the strongest confirmed UI-hang source is storage/SwiftData/filesystem work on `@MainActor`.
- No code fixes were applied in this branch beyond this report.
