# App Transport Security — justification

Super X plays streams from servers the USER enters themselves (their TV
provider's Xtream / M3U server address). Those provider servers are
very commonly plain HTTP, on non-standard ports, with no TLS offering
at all — there is no HTTPS endpoint to prefer or pin to. Blocking HTTP
would break playback for the majority of real user playlists, so
`NSAllowsArbitraryLoads` stays `true` in `App-Info.plist`. This is the
same posture as every comparable user-configured IPTV player.

Round 16 note: an earlier build additionally set
`NSAllowsArbitraryLoadsInWebContent` to `false` in an attempt to narrow
the exception for web content. On device that key change broke ALL
provider fetches (playlist info, series data, refresh) — the system
refused the app's own HTTP provider connections, not just web content.
The key was removed again; the ATS dictionary is back to exactly
`NSAllowsArbitraryLoads = true` and nothing else. Do not re-add
per-surface ATS keys without an on-device test against a plain-HTTP
provider first.

No first-party Super X server is exempted by this setting — the app
has none; the exception exists solely for user-entered provider hosts.
