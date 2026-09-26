#!/bin/sh
set -u

PORTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
APP_DIR="$PORTS_DIR/RGMusic"
LOG="/dev/null"
TOUCH_CONTROL=/sys/class/anbernic_misc/tpctrl
TOUCH_PREVIOUS=

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export SDL_VIDEODRIVER=wayland
export SDL_VIDEO_DOUBLE_BUFFER=1
export SDL_RENDER_VSYNC=1
export LOVE_GRAPHICS_USE_OPENGLES=1
export SDL_AUDIODRIVER=pulse
export ALSOFT_DRIVERS=pulse
export PULSE_SERVER=unix:/tmp/pulse-socket
export LD_LIBRARY_PATH="$APP_DIR/runtime/libs.aarch64:/usr/lib:/lib"
export XDG_DATA_HOME="$APP_DIR/saves"
export XDG_CONFIG_HOME="$APP_DIR/saves"
export RGMUSIC_ROOT="$APP_DIR/app"
export RGMUSIC_DATA="$APP_DIR/saves"
export RGMUSIC_LOG_DIR="$APP_DIR/logs"
export RGMUSIC_PATHS="/mnt/sdcard/Music:/mnt/mmc/Music:$APP_DIR/music"

mkdir -p "$APP_DIR/logs" "$APP_DIR/saves" "$APP_DIR/cache" "$APP_DIR/music" || exit 1
chmod +x "$APP_DIR/runtime/love.aarch64" 2>/dev/null || true
chmod +x "$APP_DIR/app/bin/rgmusic-netease.aarch64" 2>/dev/null || true

if [ -r "$TOUCH_CONTROL" ] && [ -w "$TOUCH_CONTROL" ]; then
    TOUCH_PREVIOUS=$(cat "$TOUCH_CONTROL")
    case "$TOUCH_PREVIOUS" in
        0|1)
            if printf '0\n' > "$TOUCH_CONTROL"; then
                printf '[touch] tpctrl_before=%s active=%s\n' "$TOUCH_PREVIOUS" "$(cat "$TOUCH_CONTROL")"
            else
                printf '[touch] tpctrl enable failed\n'
                TOUCH_PREVIOUS=
            fi
            ;;
        *) printf '[touch] unknown tpctrl value; unchanged\n'; TOUCH_PREVIOUS= ;;
    esac
fi

restore_touch() {
    if [ -n "$TOUCH_PREVIOUS" ] && [ "$(cat "$TOUCH_CONTROL" 2>/dev/null)" = 0 ]; then
        printf '%s\n' "$TOUCH_PREVIOUS" > "$TOUCH_CONTROL"
        printf '[touch] tpctrl_restored=%s\n' "$TOUCH_PREVIOUS"
    fi
}

trap restore_touch EXIT HUP INT TERM

{
    printf '[rgmusic] date=%s\n' "$(date -Iseconds)"
    printf '[rgmusic] app=%s\n' "$APP_DIR"
    printf '[rgmusic] paths=%s\n' "$RGMUSIC_PATHS"
    "$APP_DIR/runtime/love.aarch64" "$APP_DIR/app"
    rc=$?
    printf '[rgmusic] exit=%s date=%s\n' "$rc" "$(date -Iseconds)"
    exit "$rc"
} >> "$LOG" 2>&1