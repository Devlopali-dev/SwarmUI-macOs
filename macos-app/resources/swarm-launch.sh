#!/bin/bash
# Runs SwarmUI using only the toolchains embedded in the app bundle (no brew/system python/dotnet/git).
# Mirrors SwarmUI's launch-macos.sh + launchtools/linux-build-logic.sh, which can't be sourced as-is
# because they put ~/.dotnet and Homebrew python ahead of the embedded toolchains in PATH.
set -u

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# No spaces allowed in this path: python venv/pip tooling breaks on them ("Application Support" is out).
SUPPORT="$HOME/Library/SwarmUI"
RUNTIME="$SUPPORT/runtime"
SWARM="$SUPPORT/SwarmUI"
SWARM_REPO="${SWARM_REPO:-https://github.com/mcmonkeyprojects/SwarmUI}"

log() {
    echo "[launcher] $*"
}

mkdir -p "$SUPPORT"

bundle_stamp="$(cat "$RES/toolchains/VERSION")"
if [ ! -f "$RUNTIME/VERSION" ] || [ "$(cat "$RUNTIME/VERSION")" != "$bundle_stamp" ]; then
    log "Installing embedded toolchains ($bundle_stamp)..."
    mkdir -p "$RUNTIME"
    for tool in dotnet git; do
        rm -rf "$RUNTIME/$tool"
        ditto "$RES/toolchains/$tool" "$RUNTIME/$tool" || exit 1
    done
    # Never replace python in place: the ComfyUI venv is bound to this interpreter path.
    if [ ! -x "$RUNTIME/python/bin/python3.11" ]; then
        ditto "$RES/toolchains/python" "$RUNTIME/python" || exit 1
    fi
    xattr -dr com.apple.quarantine "$RUNTIME" 2>/dev/null
    echo "$bundle_stamp" > "$RUNTIME/VERSION"
fi

# Homebrew is appended last only so optional tools like ffmpeg are still found; embedded tools always win.
export PATH="$RUNTIME/python/bin:$RUNTIME/git/bin:$RUNTIME/dotnet:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export DOTNET_ROOT="$RUNTIME/dotnet"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_CLI_UI_LANGUAGE=en
export GIT_EXEC_PATH="$RUNTIME/git/libexec/git-core"
export GIT_TEMPLATE_DIR="$RUNTIME/git/share/git-core/templates"
if [ -f "$RUNTIME/git/ssl/cacert.pem" ]; then
    export GIT_SSL_CAINFO="$RUNTIME/git/ssl/cacert.pem"
fi
export PYTORCH_ENABLE_MPS_FALLBACK=1
unset PYTHONHOME PYTHONPATH VIRTUAL_ENV CONDA_PREFIX

# Written by the menu bar "Limite mémoire" submenu: SWARM_RAM_LIMIT_GB + PYTORCH_MPS_*_WATERMARK_RATIO.
SWARM_RAM_LIMIT_GB=""
if [ -f "$SUPPORT/launcher.env" ]; then
    set -a
    source "$SUPPORT/launcher.env"
    set +a
fi

if [ ! -d "$SWARM/.git" ]; then
    log "Downloading SwarmUI from $SWARM_REPO ..."
    rm -rf "$SWARM.partial"
    git clone "$SWARM_REPO" "$SWARM.partial" || exit 1
    rm -rf "$SWARM"
    mv "$SWARM.partial" "$SWARM"
fi

cd "$SWARM" || exit 1

build_swarm() {
    mkdir -p ./src/bin
    if [ -f ./src/bin/always_pull ]; then
        log "Pulling latest changes..."
        git pull
    fi
    cur_head="$(git rev-parse HEAD)"
    if [ "$cur_head" != "$(cat src/bin/last_build 2>/dev/null)" ]; then
        touch ./src/bin/must_rebuild
    fi
    if [ -f ./src/bin/must_rebuild ]; then
        log "Rebuilding SwarmUI..."
        if [ -d ./src/bin/live_release ]; then
            rm -rf ./src/bin/live_release_backup
            mv ./src/bin/live_release ./src/bin/live_release_backup
        fi
        rm -rf ./src/bin/extensions
        rm ./src/bin/must_rebuild
    fi
    if [ ! -f src/bin/live_release/SwarmUI.dll ]; then
        dotnet build src/SwarmUI.csproj --configuration Release -o ./src/bin/live_release
        git rev-parse HEAD > src/bin/last_build
    fi
    if [ ! -f src/bin/live_release/SwarmUI.dll ] && [ -f src/bin/live_release_backup/SwarmUI.dll ]; then
        log "WARNING: build failed, restoring previous build."
        rm -rf ./src/bin/live_release
        mv ./src/bin/live_release_backup ./src/bin/live_release
    fi
}

# ComfyUI sizes its model loading from total system RAM, so the MPS hard cap alone would just OOM.
# --reserve-vram (total - limit) makes it plan as if the Mac only had the limit.
apply_reserve_vram() {
    local fds="Data/Backends.fds"
    if [ ! -f "$fds" ]; then
        return 0
    fi
    local total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    local reserve=""
    if [ -n "$SWARM_RAM_LIMIT_GB" ] && [ "$SWARM_RAM_LIMIT_GB" -lt "$total_gb" ]; then
        reserve=$(( total_gb - SWARM_RAM_LIMIT_GB ))
        log "Memory limit: ${SWARM_RAM_LIMIT_GB} GB of ${total_gb} GB (ComfyUI --reserve-vram $reserve)"
    fi
    RESERVE="$reserve" python3 - "$fds" <<'EOF'
import os, re, sys
path = sys.argv[1]
reserve = os.environ["RESERVE"]
with open(path, encoding="utf-8") as f:
    original = f.read()
lines = original.split("\n")
kind = None
for i, line in enumerate(lines):
    m = re.match(r"^\ttype: (.*)$", line)
    if m:
        kind = m.group(1).strip()
    m = re.match(r"^(\t\tExtraArgs: )(.*)$", line)
    if m and kind == "comfyui_selfstart":
        args = "" if m.group(2) == "\\x" else m.group(2)
        args = re.sub(r"\s*--reserve-vram\s+[0-9.]+", "", args).strip()
        if reserve:
            args = (args + " --reserve-vram " + reserve).strip()
        lines[i] = m.group(1) + (args if args else "\\x")
updated = "\n".join(lines)
if updated != original:
    with open(path, "w", encoding="utf-8") as f:
        f.write(updated)
EOF
}

export ASPNETCORE_ENVIRONMENT="Production"

# Exit code 42 is SwarmUI's "restart me" signal (update button, extension install...).
while true; do
    build_swarm
    apply_reserve_vram
    ./src/bin/live_release/SwarmUI --launch_mode none "$@"
    code=$?
    if [ $code -ne 42 ]; then
        exit $code
    fi
    log "Restart requested by SwarmUI."
done
