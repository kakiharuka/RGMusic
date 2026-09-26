# Changelog

## r0.75

- Fixed online playback stopping when mpv reached end-of-file and entered idle state.
- Detect mpv `idle-active` and advance to the next track.
- Improved first-track startup by avoiding stale PID cleanup races.
- Wait for old mpv processes to exit before starting another track.
- Improved direct-stream retry behavior and removed audio cache fallback.
- Improved online status reporting while mpv is loading or buffering.
- Removed bundled demo audio.