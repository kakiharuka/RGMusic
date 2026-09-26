# RG Music Netease Helper

This helper is a small ARM64 sidecar for RG Music. It is based on the public
request flow and endpoint design used by go-musicfox / netease-music, but does
not include the go-musicfox TUI or its UnblockNeteaseMusic processor.

Supported commands:

- status
- login-start
- login-poll
- playlists
- playlist <id>
- search <query> [limit]
- resolve <song-id> [quality]
- stream <song-id> [quality]
- art <song-id> [cover-url]
- prepare <song-id> [quality]
- clear-cache
- logout

The helper writes machine-readable UTF-8 TSV output to the file passed with
`-out`. It stores cookies and cache files only below the directory passed with
`-data`.

Build for RGDS Plus (ARM64):

```powershell
$env:CGO_ENABLED="0"
$env:GOOS="linux"
$env:GOARCH="arm64"
go build -trimpath -ldflags="-s -w" -o rgmusic-netease.aarch64 .
```

Security and scope:

- No gray-song unlocking.
- No VIP or copyright bypass.
- Online tracks are prepared from the URL returned for the logged-in account.
- Unavailable tracks remain unavailable.