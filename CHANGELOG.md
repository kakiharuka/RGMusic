# Changelog

## r0.76

- Added automatic PulseAudio routing when headphones are inserted or removed.
- Redesigned the dual-screen interface with a light flat theme, aligned cover/lyrics layout, centered transport controls, and clearer playback status icons.
- Added NetEase membership-state display, account switching, and clearer handling of stale login sessions.
- Improved unavailable-track handling: songs without a playable URL now show a clear message and are not repeatedly requested.
- Refined the lower-screen layout, volume controls, shuffle/repeat indicators, and footer hints.

## r0.75

- Fixed online playback stopping when mpv reached end-of-file and entered idle state.
- Detect mpv `idle-active` and advance to the next track.
- Improved first-track startup by avoiding stale PID cleanup races.
- Wait for old mpv processes to exit before starting another track.
- Improved direct-stream retry behavior and removed audio cache fallback.
- Improved online status reporting while mpv is loading or buffering.
- Removed bundled demo audio.