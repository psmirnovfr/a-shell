#!/bin/sh
# Fetch the xcframeworks that this fork's project.pbxproj references but that the
# bundled downloadFrameworks.sh / xcfs Package.swift do NOT provide.
#
# These live as assets in existing holzschu releases; we place each .xcframework at
# the exact path the project expects. Idempotent. See docs/AGENTIC.md.
#
# Usage:
#   sh scripts/fetch_missing_frameworks.sh          # mini set (enough for a-Shell-mini)
#   sh scripts/fetch_missing_frameworks.sh --full   # + geo/scientific set (a-Shell full)
#
# NOTE: the full a-Shell scheme also needs xetex/euptex/ptexenc/xdvipdfmx and perlC,
# which have NO prebuilt release anywhere and must be built from source — so a full
# link is not achievable from prebuilt assets. a-Shell-mini IS.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PA="https://github.com/holzschu/Python-aux/releases/download/1.0"
IOS="https://github.com/holzschu/ios_system/releases/download/v3.0.5"

# dl <zip-url> <destination-parent-dir>
# Places <name>.xcframework (from the zip filename) directly under the parent dir.
dl() {
    url="$1"; destdir="$2"
    name="$(basename "$url" .zip)"          # e.g. freetype.xcframework
    if [ -d "$destdir/$name" ]; then
        echo "skip (present): $destdir/$name"
        return 0
    fi
    echo "fetch: $name -> $destdir/"
    curl -sL -o "$TMP/f.zip" "$url"
    rm -rf "$TMP/x"; mkdir -p "$TMP/x"
    (cd "$TMP/x" && unzip -q ../f.zip)
    fw="$(find "$TMP/x" -maxdepth 3 -name '*.xcframework' -type d | head -1)"
    if [ -z "$fw" ]; then echo "ERROR: no .xcframework in $url" >&2; exit 1; fi
    mkdir -p "$destdir"
    rm -rf "$destdir/$name"
    mv "$fw" "$destdir/$name"
}

echo "== mini set =="
dl "$PA/freetype.xcframework.zip" cpython/Python-aux
dl "$PA/harfbuzz.xcframework.zip" cpython/Python-aux
dl "$PA/libpng.xcframework.zip"   cpython/Python-aux
dl "$PA/openssl.xcframework.zip"  xcfs/.build/artifacts/xcfs/openssl
dl "$IOS/ssh_agent.xcframework.zip" xcfs/.build/artifacts/xcfs/ssh_agent
dl "$IOS/ssh_cmdA.xcframework.zip"  xcfs/.build/artifacts/xcfs/ssh_cmdA
dl "$IOS/sshd.xcframework.zip"      xcfs/.build/artifacts/xcfs/sshd

if [ "$1" = "--full" ]; then
    echo "== full extras (geo/scientific) =="
    for f in libgdal libgeos libgeos_c libproj libspatialindex libspatialindex_c; do
        dl "$PA/$f.xcframework.zip" cpython/Python-aux
    done
    dl "$PA/openblas.xcframework.zip" cpython/XcFrameworks
    echo "WARNING: full still cannot link — xetex/euptex/ptexenc/xdvipdfmx/perlC have no"
    echo "         prebuilt binaries. Use the a-Shell-mini scheme for a working build."
fi

echo "Done."
