# Using RG Music as an AI Development Reference

This guide is for developers who want to use RG Music as a reference while building a different application for the RGDS Plus with AI assistance.

RG Music is a working example, not a universal hardware abstraction layer. It has only been tested on the Anbernic RGDS Plus. Every other device, firmware, and application still needs its own hardware and runtime verification.

## What can be learned from this project

### Application packaging

The APPS-style layout, launcher environment, runtime library path, and icon layout are useful references. Read:

- `source/RG Music.sh`
- `tools/build_apps_package.ps1`
- `assets/README-APPS.txt`

Do not assume another launcher or firmware uses the same environment variables.

### Dual-screen application structure

RG Music treats two 1024x768 displays as one logical 2048x768 canvas and applies a global scale at draw time. This is a useful pattern for any dual-screen UI, but screen ordering and rotation must be verified on the target device.

### Input abstraction

Button mappings are isolated in `controls.lua`, while `touch_evdev.lua` provides a fallback when SDL does not report every touchscreen event. This separation is useful for adapting an application to new controls without rewriting the main program.

### Sidecar process model

The NetEase helper is a separate Go process. The LÖVE client communicates through temporary output files. This keeps network and credential handling outside the UI process.

The exact protocol is not a requirement. A new project can use a local socket, HTTP server, stdin/stdout, or shared memory instead.

### External player management

`mpv.lua` demonstrates:

- unique IPC sockets and PID files per playback
- cancellation and process cleanup
- status polling
- buffering, loading, and confirmed playback states
- handling `idle-active` as an EOF signal

These patterns can be reused for a video player, podcast player, game launcher, or another media application.

### Release and privacy discipline

The packaging scripts and repository rules show how to keep runtime builds separate from source and how to exclude account data, caches, logs, music, and test files.

## Suggested workflow for a new AI-assisted app

### 1. Define the target device support boundary

Record the exact tested model and firmware. Do not write "all ARM64 handhelds" unless each device has been tested.

### 2. Build a capability matrix

For the new device or application, verify:

- display count, resolution, order, and rotation
- touchscreen and gamepad event devices
- audio server and output device
- suspend and Wi-Fi behavior
- writable directories
- available runtimes and libraries
- launcher/package conventions

### 3. Start with a minimal bring-up application

Before building the full product, make a tiny program that only proves:

- opens a window on both screens
- reads one button
- reads one touchscreen coordinate
- plays a short local sound
- writes and deletes a temporary file
- exits cleanly

This prevents UI work from masking hardware problems.

### 4. Map subsystems from RG Music

Use the project as a map, not as a black box:

| Need | RG Music reference |
|---|---|
| Launcher environment | `source/RG Music.sh` |
| Packaging | `tools/build_apps_package.ps1` |
| Local scanning | `library.lua` |
| Input mapping | `controls.lua` |
| Touch fallback | `touch_evdev.lua` |
| Sidecar process | `netease.lua` and `source/RGMusicNetease` |
| Media process lifecycle | `mpv.lua` |
| Dual-screen coordinates | `main.lua` |

### 5. Use AI in small, evidence-based steps

Ask the model to inspect the current files and real command output. Then request one subsystem at a time:

1. capability inventory
2. minimal hello-world
3. input/output proof
4. audio/network proof
5. main feature implementation
6. packaging and privacy audit

Do not ask an AI to assume that an RGDS Plus behavior applies to another handheld.

## Example prompts

### Analyze the reference project

```text
Read RG Music as a reference project. Produce a subsystem map showing what can be reused for a new ARM64 handheld application and what is hardware-specific. Do not assume compatibility with another device.
```

### Plan a new application

```text
I want to build a different application for the RGDS Plus. Use RG Music only as a reference. First produce a capability checklist and a minimal bring-up plan. Do not write feature code until the display, input, audio, storage, and launcher paths are verified.
```

### Reuse a subsystem

```text
Study mpv.lua and explain which lifecycle patterns can be reused for another media application. Separate general patterns from RGDS Plus-specific assumptions and list the exact tests required before reuse.
```

### Create a compatibility statement

```text
Review this project and produce a precise compatibility statement. State which device and firmware were tested and explicitly mark every other device as unverified.
```

### Privacy review before release

```text
Audit the repository and release archive for account data, cookies, private paths, music files, logs, and debug artifacts. Report findings without printing credential values.
```

## What not to assume

Do not assume that another device has the same:

- screen order or orientation
- input event numbers
- Wayland or X11 setup
- PulseAudio socket
- Wi-Fi power-saving behavior
- suspend policy
- writable directory layout
- launcher format
- available libraries
- CPU/GPU performance
- network stack behavior

## Goal

The value of RG Music as a reference is not that another project should copy it unchanged. The value is that it provides tested examples of packaging, dual-screen structure, process isolation, media lifecycle, and privacy-conscious release engineering that another project can adapt after independent verification.