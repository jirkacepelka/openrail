#!/usr/bin/env bash
# Install Godot and its export templates for CI (Linux or Windows via Git Bash).
# Usage: tools/setup-godot.sh linux|windows
# Result: $HOME/godot-ci/godot (Windows: godot.exe, the console build) and the
# templates in Godot's per-user template folder. Skips what is already there,
# so the two folders can be cached between runs.
set -euo pipefail
platform="${1:?usage: setup-godot.sh linux|windows}"
ver="4.4.1"
base="https://github.com/godotengine/godot/releases/download/${ver}-stable"
dir="$HOME/godot-ci"
mkdir -p "$dir"

py="python3"
command -v python3 >/dev/null 2>&1 || py="python"

# Usage: extract ZIP DEST [MEMBER:TARGETNAME ...]; only listed members, renamed.
extract() {
  "$py" - "$@" <<'PY'
import sys, zipfile, os
zpath, dest, *pairs = sys.argv[1:]
os.makedirs(dest, exist_ok=True)
with zipfile.ZipFile(zpath) as z:
    for pair in pairs:
        member, name = pair.split(":", 1)
        with z.open(member) as src, open(os.path.join(dest, name), "wb") as dst:
            while chunk := src.read(1 << 20):
                dst.write(chunk)
PY
}

if [ "$platform" = "windows" ]; then
  editor="Godot_v${ver}-stable_win64"
  godot_bin="$dir/godot.exe"
  tpl_dir="${APPDATA}/Godot/export_templates/${ver}.stable"
  tpl_files=("templates/windows_release_x86_64.exe:windows_release_x86_64.exe"
    "templates/windows_release_x86_64_console.exe:windows_release_x86_64_console.exe"
    "templates/version.txt:version.txt")
else
  editor="Godot_v${ver}-stable_linux.x86_64"
  godot_bin="$dir/godot"
  tpl_dir="$HOME/.local/share/godot/export_templates/${ver}.stable"
  tpl_files=("templates/linux_release.x86_64:linux_release.x86_64"
    "templates/version.txt:version.txt")
fi

if [ ! -f "$godot_bin" ]; then
  curl -fsSL --retry 3 -o "$dir/editor.zip" "$base/${editor}.zip"
  if [ "$platform" = "windows" ]; then
    extract "$dir/editor.zip" "$dir" "${editor}_console.exe:godot.exe"
  else
    extract "$dir/editor.zip" "$dir" "${editor}:godot"
    chmod +x "$godot_bin"
  fi
  rm -f "$dir/editor.zip"
fi

if [ ! -f "$tpl_dir/version.txt" ]; then
  # The template archive is about 1.2 GB; only the release template we need is kept.
  curl -fsSL --retry 3 -o "$dir/templates.tpz" "$base/Godot_v${ver}-stable_export_templates.tpz"
  extract "$dir/templates.tpz" "$tpl_dir" "${tpl_files[@]}"
  rm -f "$dir/templates.tpz"
fi

if [ "$platform" = "windows" ]; then
  # rcedit writes the icon and version info into OpenRail.exe.
  rcedit="$dir/rcedit-x64.exe"
  if [ ! -f "$rcedit" ]; then
    curl -fsSL --retry 3 -o "$rcedit" "https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe"
  fi
  settings_dir="${APPDATA}/Godot"
  mkdir -p "$settings_dir"
  win_rcedit="$(cygpath -m "$rcedit")"
  printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\nexport/windows/rcedit = "%s"\n' \
    "$win_rcedit" > "$settings_dir/editor_settings-4.4.tres"
fi

echo "godot: $godot_bin"
echo "templates: $tpl_dir"
