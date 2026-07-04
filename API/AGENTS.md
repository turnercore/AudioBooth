# API Agent Guide

## Purpose

Audiobookshelf client package for authentication, network requests, service APIs, DTOs, discovery, sessions, logging hooks, and shared image pipeline configuration.

## Ownership

- Own files under `API/`.
- Public types here are consumed by the app, models, widgets, watch app, and intents through package dependencies.
- Keep this package usable by iOS and watchOS targets declared in `API/Package.swift`.

## Local Contracts

- Treat auth tokens, cookies, custom headers, OIDC values, and server URLs as sensitive.
- Do not log raw credentials, auth callback query values, cookie headers, or auth response bodies.
- Keep network request construction centralized in `NetworkService` unless a platform API requires a different transport.
- Avoid adding UI dependencies to `API`; `NukeUI` re-export is known debt and should not be expanded.
- Preserve the current `Models -> API` dependency only until DTO-to-local mapping is moved out of `Models`; do not add new model-layer API coupling.

## Work Guidance

- Prefer small service methods over new global managers.
- When changing token refresh, check `CredentialsActor`, `AuthenticationService`, and `NetworkService` together.
- When changing request headers, check image loading, watch connectivity, and custom headers.
- Keep local HTTP support intentional and visible; do not silently downgrade credentialed requests.

## Verification

- Prefer the root generic iOS `xcodebuild` command for validation.
- `swift test` in this package is not currently a reliable standalone check.

## Child DOX Index

