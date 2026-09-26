# Contributing

Thanks for considering a contribution to RG Music.

## Before opening a pull request

- Keep changes focused and describe the user-visible behavior.
- Do not commit cookies, account data, device IDs, private keys, music files, cache files, or logs.
- Keep the user's account data outside the repository.
- Test on an RGDS Plus or describe why hardware testing was not possible.
- Run the syntax and backend tests listed below.

## Development checks

Lua syntax:

```powershell
npx --yes luaparse source/RGMusic/app/main.lua
npx --yes luaparse source/RGMusic/app/controls.lua
npx --yes luaparse source/RGMusic/app/netease.lua
npx --yes luaparse source/RGMusic/app/mpv.lua
```

Backend:

```powershell
Set-Location source/RGMusicNetease
go test ./...
go build -trimpath -ldflags="-s -w" -o ../RGMusic/app/bin/rgmusic-netease.aarch64 .
```

## Reporting issues

Please include:

- RGDS Plus firmware version
- Local or online playback
- Whether the issue reproduces consistently
- Relevant, redacted status text

Do not attach `cookies.json`, `account.json`, login QR codes, or complete personal library listings.