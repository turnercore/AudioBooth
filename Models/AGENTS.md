# Models Agent Guide

## Purpose

Local model package for SwiftData persistence, offline/download metadata, playback progress, bookmarks, sessions, and app-intent-visible model state.

## Ownership

- Own files under `Models/`.
- This package is consumed by the app, widgets, watch-related code, and `PlayerIntents`.
- SwiftData schema and migrations live here.

## Local Contracts

- Treat SwiftData persistence changes as data-loss sensitive.
- Do not delete or recreate persistent stores without preserving recoverable data first.
- Save/delete helpers that declare `throws` should surface `context.save()` failures instead of swallowing them.
- Do not import `API` or add remote DTO mapping here; keep DTO-to-local mapping in app-side adapter code.
- Keep model properties local-domain focused; avoid exposing remote API enum types from local SwiftData models.
- Keep play-session source URLs transient. Resolve server-provided HLS references onto the authenticated session origin and reject absolute or non-HLS overrides.

## Work Guidance

- Read `Models/Sources/Models/AudiobookshelfSchema.swift` before schema changes.
- Check all app/widget/watch callers before changing public model fields.
- Keep filesystem path helpers minimal and app-group aware.
- For observation helpers, avoid unbounded main-actor work and make cancellation explicit.

## Verification

- Prefer the root generic iOS `xcodebuild` command for validation.
- `swift test` in this package is not currently a reliable standalone check.

## Child DOX Index
