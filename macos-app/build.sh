#!/bin/bash
# Builds dist/SwarmUI-<version>.dmg: a self-contained Apple Silicon app embedding
# .NET SDK 10, a standalone Python 3.11 and a portable git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${VERSION:-1.0.0}"
SWARM_SRC="${SWARM_SRC:-$ROOT/..}"
CACHE="$ROOT/cache"
BUILD="$ROOT/build"
DIST="$ROOT/dist"

PY_VERSION="3.11.16"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.11.16%2B20260901-aarch64-apple-darwin-install_only.tar.gz"
PY_SHA="50424fa409e8ae84b82a3052522f64695b47dff2158b70bb7358e0ebd6c085c9"
GIT_VERSION="2.53.0"
GIT_URL="https://github.com/desktop/dugite-native/releases/download/v2.53.0-4/dugite-native-v2.53.0-4098283-macOS-arm64.tar.gz"
GIT_SHA="f9dc64635a5b62fbd7ad95db73268bbb8912255ac516d65d37bf7af22fcb8ffe"
DOTNET_CHANNEL="10.0"

step() {
    printf '\n==> %s\n' "$*"
}

fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ] && echo "$sha  $dest" | shasum -a 256 -c --status; then
        return
    fi
    curl -fL --retry 3 -o "$dest.tmp" "$url"
    echo "$sha  $dest.tmp" | shasum -a 256 -c --status || { echo "Checksum mismatch for $url" >&2; exit 1; }
    mv "$dest.tmp" "$dest"
}

if [ "$(uname -m)" != "arm64" ]; then
    echo "Build on an Apple Silicon Mac (SwarmUI only supports M-series on macOS)." >&2
    exit 1
fi

mkdir -p "$CACHE" "$DIST"
rm -rf "$BUILD"
APP="$BUILD/SwarmUI.app"
TOOLS="$APP/Contents/Resources/toolchains"
mkdir -p "$APP/Contents/MacOS" "$TOOLS"

step "Python $PY_VERSION (standalone)"
fetch "$PY_URL" "$PY_SHA" "$CACHE/python.tar.gz"
tar -xzf "$CACHE/python.tar.gz" -C "$TOOLS"
"$TOOLS/python/bin/python3.11" -c "import venv, ensurepip, ssl; print('python ok', ssl.OPENSSL_VERSION)"

step "git $GIT_VERSION (portable)"
fetch "$GIT_URL" "$GIT_SHA" "$CACHE/git.tar.gz"
mkdir -p "$TOOLS/git"
tar -xzf "$CACHE/git.tar.gz" -C "$TOOLS/git"
GIT_EXEC_PATH="$TOOLS/git/libexec/git-core" "$TOOLS/git/bin/git" --version

step ".NET SDK $DOTNET_CHANNEL"
if [ ! -x "$CACHE/dotnet/dotnet" ]; then
    curl -fL --retry 3 -o "$CACHE/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
    bash "$CACHE/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --architecture arm64 --install-dir "$CACHE/dotnet" --no-path
fi
DOTNET_VERSION="$(DOTNET_CLI_TELEMETRY_OPTOUT=1 "$CACHE/dotnet/dotnet" --version)"
ditto "$CACHE/dotnet" "$TOOLS/dotnet"
echo "dotnet sdk $DOTNET_VERSION"

echo "$VERSION-py$PY_VERSION-git$GIT_VERSION-dotnet$DOTNET_VERSION" > "$TOOLS/VERSION"

step "Launcher (Swift)"
(cd "$ROOT/Launcher" && swift build -c release --arch arm64)
BIN_DIR="$(cd "$ROOT/Launcher" && swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_DIR/SwarmUILauncher" "$APP/Contents/MacOS/SwarmUILauncher"
cp "$ROOT/resources/swarm-launch.sh" "$APP/Contents/Resources/swarm-launch.sh"
chmod +x "$APP/Contents/Resources/swarm-launch.sh"
sed "s/__VERSION__/$VERSION/g" "$ROOT/resources/Info.plist" > "$APP/Contents/Info.plist"

step "Icon"
ICON_SRC="$SWARM_SRC/src/wwwroot/favicon.ico"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -s format png "$ICON_SRC" --out "$BUILD/icon.png" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size "$BUILD/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "No icon source at $ICON_SRC, skipping (set SWARM_SRC to a SwarmUI checkout)."
fi

step "Ad-hoc signing"
codesign --force --sign - "$APP/Contents/MacOS/SwarmUILauncher"
codesign --force --sign - "$APP"

step "DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SwarmUI.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/SwarmUI-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "SwarmUI" -srcfolder "$STAGE" -ov -format ULFO "$DMG"

step "Done: $DMG ($(du -h "$DMG" | cut -f1))"
