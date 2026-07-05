# AirPlay HomePod Failure Checklist

## Symptom

- HomePod AirPlay starts, plays roughly 0-2 seconds, then playback fails and the route falls back to the phone/AirPods.
- Observed AVFoundation failure: `AVFoundationErrorDomain/-11800`, underlying `NSOSStatusErrorDomain/-71974`.
- This also happens on the base app, so personal-branch purchase/ScoreKit removals are not the cause.

## Tried And Reverted

- AirPlay route-change suppression windows.
- Delayed queue rebuild after AirPlay route selection.
- Forcing remote playback immediately on AirPlay route changes.
- AirPlay-specific seek tolerance.
- AirPlay-specific EQ/audioMix removal.
- Volume/interruption/stalled-event suppression during handoff.

These did not change the failure, so they were removed.

## Kept

- `AVQueuePlayer.allowsExternalPlayback = true`.
- Do not attach custom AVURLAsset headers to `/public/session/.../track/...` URLs.
- Wait for `AVPlayerItem.readyToPlay` before autoplaying a newly queued item.
- Treat `failedToPlayToEnd` as a playback error, not a recoverable stall.
- Preserve server `audioTracks[].contentUrl` and use `/hls...` URLs when the server returns them.
- For HLS assets, include auth headers and set `preferredForwardBufferDuration = 50`, matching the Audiobookshelf iOS app.
- If a downloaded item fails while AirPlay is active, allow fallback to a remote transcoded session.

## Still To Test

- Reproduce HomePod handoff with this cleaned build.
- Confirm the first failure triggers a new playback session with `forceTranscode = true`.
- Confirm the resulting track URL is `/hls...`, not `/public/session/.../track/...`.
- Confirm playback either continues on HomePod or produces a different HLS-specific error.

## If It Still Fails

- Add one redacted log line for selected asset shape: `publicSession`, `hls`, `file`, extension, and route.
- Compare server response body for `audioTracks[].contentUrl` on force-transcoded sessions.
- Test a short known-good AAC item over HLS to separate long-file/deep-offset behavior from AirPlay transport behavior.
