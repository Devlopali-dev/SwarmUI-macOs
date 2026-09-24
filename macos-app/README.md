# SwarmUI macOS app

Self-contained SwarmUI app for Apple Silicon Macs, shipped as a `.dmg`. No Homebrew, .NET, Python or git install required: the app embeds .NET SDK 10, a standalone Python 3.11 and a portable git.

## Build

```bash
./macos-app/build.sh            # -> macos-app/dist/SwarmUI-1.0.0.dmg
VERSION=1.1.0 ./macos-app/build.sh
```

Requires an Apple Silicon Mac with Xcode (or the Command Line Tools) for `swift build`. Downloads are pinned and checksum-verified, then cached in `macos-app/cache/`.

## How it works

- `SwarmUI.app` is a menu bar app (Swift, `Launcher/`) that runs `resources/swarm-launch.sh` in its own process group.
- On first launch the embedded toolchains are copied to `~/Library/SwarmUI/runtime`, this fork (Devlopali-dev/SwarmUI-macOs, override with the `SWARM_REPO` env var) is cloned to `~/Library/SwarmUI/SwarmUI` and built. The browser then opens on the SwarmUI install wizard, which creates the ComfyUI venv with the embedded Python 3.11.
- `swarm-launch.sh` mirrors `launch-macos.sh` + `launchtools/linux-build-logic.sh`, but only puts the embedded toolchains on `PATH`. Restart (exit code 42), the update button and extension builds work as upstream.
- Data lives in `~/Library/SwarmUI` (no spaces in the path, which Python tooling needs).

## Menu

Open SwarmUI, start / stop / restart the server, models and outputs folders, logs, launch at login, and **Memory limit** (16 / 24 / 32 GB / none). The memory limit sets a hard PyTorch MPS cap (`PYTORCH_MPS_*_WATERMARK_RATIO`) and adds `--reserve-vram` to the ComfyUI self-start backend so it plans model loading for that amount of memory. SwarmUI's own server info still shows the Mac's physical RAM.

## Install / uninstall

The app is ad-hoc signed, not notarized: right-click > Open on first launch. To uninstall, delete the app and `~/Library/SwarmUI`.
