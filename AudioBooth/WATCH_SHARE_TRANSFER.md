# Watch Share Transfer Contract

## Server baseline

- Verified deployed Audiobookshelf version: 2.36.0 at `/audiobookshelf/status`.
- Public DNS resolves `audiobookshelf.themonstersarecom.ing` to RackNerd `104.168.38.149`. Local Tailscale DNS overrides it with `100.92.133.126`; transfer URLs must use the hostname, never either literal address.
- The expired sample share is externally reachable and returns `Media item not found or expired`, confirming public routing through the `/audiobookshelf` base path.

## Authenticated iPhone operations

The authenticated iPhone is the only component allowed to create or revoke shares.

Create:

```http
POST /audiobookshelf/api/share/mediaitem
Authorization: Bearer <iPhone credential>
Content-Type: application/json

{
  "slug": "<random unguessable slug>",
  "mediaItemType": "book",
  "mediaItemId": "<Book.Media.id>",
  "expiresAt": <absolute Unix milliseconds>,
  "isDownloadable": true
}
```

Audiobookshelf 2.36.0 requires an admin-or-higher account. It returns `201` with the share `id`, `slug`, ISO-8601 expiry string, and downloadable flag. Duplicate media or slug returns `409`.

Revoke:

```http
DELETE /audiobookshelf/api/share/mediaitem/<share-id>
Authorization: Bearer <iPhone credential>
```

Success returns `204` and invalidates active share sessions. There is no expiry-update endpoint; recreate instead.

## Credential-free Watch bootstrap

The Watch receives the public hostname/base path, random share slug, bounded expiry, and expected book/track identity. It receives no bearer token, API key, custom header, local filesystem path, or permanent account credential.

A share page URL is not itself a media URL. The Watch first initializes a public share session:

```http
GET /audiobookshelf/public/share/<slug>
```

The response sets an HttpOnly `share_session_id` cookie and includes `playbackSession.audioTracks`. Each track provides an index, duration, MIME type, filename/extension metadata, byte size, and content URL shaped as:

```text
/audiobookshelf/public/share/<slug>/track/<index>
```

The track endpoints require the share-session cookie and send the original audio files. Because `share_session_id` identifies only one public share, the Watch durably queues offers and bootstraps/downloads only one public-share job at a time. A multi-track audiobook is downloaded track-by-track; the `/download` endpoint would instead create a ZIP for directory books and is not used.

Cover artwork is available at `/public/share/<slug>/cover` with the same cookie, but remains optional.

## Expiry and cleanup

- The create request sends `expiresAt` as absolute Unix milliseconds; `0` means permanent and must not be used. The 2.36 response returns the expiry as ISO-8601 (numeric milliseconds are also accepted for compatibility).
- Expired shares are deleted by the server and public initialization returns `404`.
- The iPhone revokes a share after confirmed Watch installation or cancellation. It also cleans up stale/failed jobs when connectivity returns.
- If a share expires during transfer, the Watch asks the iPhone for a replacement. Already validated track files remain reusable; partial-file reuse depends on HTTP validators/range support.
- Active share URLs are persisted only for recoverable transfers and removed after completion, cancellation, or terminal cleanup.

## Background download behavior

Use a stable `URLSessionConfiguration.background(withIdentifier:)` and download tasks, not data tasks. Set `sessionSendsLaunchEvents = true`; restore the session from `WKURLSessionRefreshBackgroundTask.sessionIdentifier`; move temporary files before returning from `didFinishDownloadingTo`; complete the WatchKit task only after session delegate callbacks finish.

Background download tasks run outside the Watch app process and continue through wrist-down suspension/system termination. Scheduling remains system-controlled. Automatic interruption recovery depends on server support for HTTP ranges and stable validators. Audiobookshelf serves tracks with Express `sendFile`, which supports byte-range requests; live range and validator behavior must be confirmed with a newly created share before hardware acceptance.

## Source evidence

Audiobookshelf 2.36.0 upstream:

- `server/routers/ApiRouter.js`: authenticated create/delete routes.
- `server/routers/PublicRouter.js`: public initialize, track, cover, and download routes.
- `server/controllers/ShareController.js`: request validation, cookie session, track mapping, original-file serving, and ZIP behavior.
- `server/managers/ShareManager.js`: expiry and revocation lifecycle.
- `server/models/MediaItemShare.js`: public response shape.

Apple:

- `WKURLSessionRefreshBackgroundTask`
- `Using background tasks` (WatchKit)
- `Downloading files in the background` (Foundation)
- WWDC21 10003, “There and back again: Data transfer on Apple Watch”
- WWDC23 10006, “Build robust and resumable file transfers”
