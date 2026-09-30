#!/usr/bin/env bash
# Copy the built openrail-gdext library into client/bin so Godot can load it
# and include it in exports. Usage: tools/copy-gdext.sh [debug|release]
# Run `cargo build [--release] -p openrail-gdext` first. Works on Linux and
# on Windows (Git Bash).
set -euo pipefail
profile="${1:-debug}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${CARGO_TARGET_DIR:-$root/target}/$profile"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) lib="openrail_gdext.dll" ;;
  *) lib="libopenrail_gdext.so" ;;
esac
if [ ! -f "$target/$lib" ]; then
  echo "missing $target/$lib: run cargo build -p openrail-gdext first" >&2
  exit 1
fi
mkdir -p "$root/client/bin"
cp "$target/$lib" "$root/client/bin/$lib"
echo "copied $lib ($profile) to client/bin"
