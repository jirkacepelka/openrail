#!/usr/bin/env bash
# Write the workspace version (Cargo.toml [workspace.package]) into the
# export presets, so the version lives in one place. Prints the version.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n '/^\[workspace.package\]/,/^\[/{s/^version *= *"\(.*\)"/\1/p}' "$root/Cargo.toml" | head -n1)"
[ -n "$version" ] || { echo "cannot read version from Cargo.toml" >&2; exit 1; }
sed -i.bak -E \
  -e "s/^(application\/(file_version|product_version)=)\".*\"/\1\"$version.0\"/" \
  "$root/client/export_presets.cfg"
rm -f "$root/client/export_presets.cfg.bak"
echo "$version"
