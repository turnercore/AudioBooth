# API Agent Guide

## Purpose

Audiobookshelf client package for authentication, network requests, service APIs, DTOs, discovery, sessions, logging hooks, and shared image pipeline configuration.

## Ownership

- Own files under `API/`.
- Public types here are consumed by the app, widgets, watch app, and intents through package dependencies.
- Unit tests for API response compatibility live under `API/Tests/APITests/`.
- Keep this package usable by iOS and watchOS targets declared in `API/Package.swift`.

## Local Contracts

- Treat auth tokens, cookies, custom headers, OIDC values, and server URLs as sensitive.
- Do not log raw credentials, auth callback query values, cookie headers, or auth response bodies.
- Keep network request construction centralized in `NetworkService` unless a platform API requires a different transport.
- Avoid adding UI dependencies to `API`; UI files that use `LazyImage` should import `NukeUI` explicitly.
- Keep DTO-to-local model mapping in app-side adapter code; do not reintroduce a `Models -> API` dependency.
- Preserve server-provided play-session source hints such as `AudioTrack.contentUrl`; treat their values as sensitive playback credentials when logging.

## Work Guidance

- Prefer small service methods over new global managers.
- When changing token refresh, check `CredentialsActor`, `AuthenticationService`, and `NetworkService` together.
- When changing request headers, check image loading, watch connectivity, and custom headers.
- Keep local HTTP support intentional and visible; do not silently downgrade credentialed requests.
- Rebuild the shared image pipeline when the active server or its custom headers change, while retaining the persistent image cache.
- Preserve personalized-shelf caching by default; bypass it only for explicit freshness requests such as app start or pull-to-refresh.
- When expanding the server's five-item Recent Series shelf, preserve its 60-day window and use the permission-aware series endpoint.

## Verification

- Run `cd API && swift test` for API decoder and service unit tests.
- Prefer the root generic iOS `xcodebuild` command for app integration validation.

## Child DOX Index
