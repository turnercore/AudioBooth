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
- Avoid adding new `API` imports or remote DTO mapping here. Existing `Models -> API` coupling is audit debt; move new mapping into app/API adapter code.
- Keep model properties local-domain focused; avoid exposing remote API enum types from local SwiftData models.

## Work Guidance

- Read `Models/Sources/Models/AudiobookshelfSchema.swift` before schema changes.
- Check all app/widget/watch callers before changing public model fields.
- Keep filesystem path helpers minimal and app-group aware.
- For observation helpers, avoid unbounded main-actor work and make cancellation explicit.

## Verification

- Prefer the root generic iOS `xcodebuild` command for validation.
- `swift test` in this package is not currently a reliable standalone check.

## Child DOX Index

