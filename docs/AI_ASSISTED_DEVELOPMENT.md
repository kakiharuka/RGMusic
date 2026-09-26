# AI-Assisted Development for Handheld Devices

AI can accelerate development substantially, but it is most useful when it is given actual device evidence instead of only a project description. This guide describes the workflow used while developing RG Music.

## Give the model a context pack

A useful prompt includes:

1. Device model, architecture, kernel, display server, and audio server.
2. The exact software stack and version.
3. The relevant source files or file tree.
4. Real command output from the target device.
5. A screenshot or screen recording when the bug is visual.
6. A minimal reproduction and the exact observed behavior.
7. What was already tried and what changed afterward.

Useful reconnaissance commands:

```sh
uname -a
cat /proc/device-tree/model 2>/dev/null
cat /proc/bus/input/devices
ps aux
mount
iw dev
ip address
```

Replace any IP address, account name, token, or device identifier before sharing logs publicly.

## Recommended workflow

1. Ask the model to inspect the actual files and command output.
2. Ask for the smallest diagnostic change, not a full rewrite.
3. Test on the target device.
4. Feed the result back into the model.
5. Commit only after the behavior is understood and verified.
6. Add a regression note to the changelog when the bug was hardware-specific.

## Example prompts

### Initial reconnaissance

```text
This is an ARM64 Linux handheld running Wayland. Inspect the attached file tree and the following device output. Identify the runtime, display, input, and audio assumptions that could break a LÖVE application. Do not rewrite code yet; list the exact next diagnostic commands.
```

### Hardware-specific bug

```text
The application shows "playing" but mpv has stopped advancing. Here are the IPC property values, process list, and network state from the device. Determine whether this is an mpv lifecycle bug, an audio-device problem, or a network stall. Make the smallest patch and explain how to verify it.
```

### Packaging

```text
Given this source tree and target layout, create a reproducible package script that copies only runtime files, verifies required dependencies, excludes account/cache/log/test data, and prints a SHA-256 hash.
```

### Privacy review

```text
Audit the entire archive and repository history for cookies, session tokens, account IDs, nicknames, private paths, music files, and debug logs. Compare file listings and content signatures, but do not print any credential values.
```

## Guardrails

- Never paste cookies, passwords, private keys, or login QR codes into a prompt.
- Do not publish a personal `cookies.json` or `account.json`.
- Do not let a model invent hardware behavior when an actual command can be run.
- Keep debug output in `/tmp` and remove it before release.
- Separate source repositories from generated release archives.
- Validate that generated packages contain no user data before uploading them.
- Keep third-party license notices with the code and release artifacts.

## Why this matters

Embedded development often fails because of assumptions that are true on a desktop but false on a handheld: X11 instead of Wayland, IPv6 behavior, suspend policy, FAT32 storage, audio-session lifetime, or a compositor that does not deliver the expected touch event. Real device evidence is more valuable than a larger prompt.