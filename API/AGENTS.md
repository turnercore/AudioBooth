# API Agent Guide

## Purpose

Audiobookshelf client package for authentication, network requests, service APIs, DTOs, discovery, sessions, logging hooks, and shared image pipeline configuration.

## Ownership

- Own files under `API/`.
- Public types here are consumed by the app, widgets, watch app, and intents through package dependencies.
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

## Verification

- Prefer the root generic iOS `xcodebuild` command for validation.
- `swift test` in this package is not currently a reliable standalone check.

## Child DOX Index
