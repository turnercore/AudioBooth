# PlayerIntents Agent Guide

## Purpose

App Intents package for system playback actions, app entities, and shortcuts that expose AudioBooth playback to iOS system surfaces.

## Ownership

- Own files under `PlayerIntents/`.
- This package depends on `Models` and is consumed by the app target.

## Local Contracts

- Keep intent actions small and delegate app behavior to existing playback/model APIs.
- Use `MainActor` only for state that must be read or mutated on the main actor.
- Do not add network or persistence policy here; route through app/model services.

## Work Guidance

- Preserve user-facing intent names and phrases unless the change explicitly updates system integration.
- Check related app intent files under `AudioBooth/AudioBooth/AppIntents` when changing shared types here.
- Avoid introducing dependencies beyond what the package already owns.

## Verification

- Prefer the root generic iOS `xcodebuild` command for validation.

## Child DOX Index

