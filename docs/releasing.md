# Releasing

Releases are built entirely by GitHub Actions (`.github/workflows/release.yml`)
and are unsigned: Windows SmartScreen shows "More info > Run anyway".

## Cut a release

1. Bump `version` under `[workspace.package]` in `Cargo.toml` (for example to
   `0.1.0`), run `cargo build` so `Cargo.lock` follows, commit and push.
   This is the single place the version lives; the export presets get it
   from there (`tools/set-version.sh`).
2. Tag and push:

   ```
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. Wait for the "Release" workflow (about 15 to 25 minutes on a cold cache).
   It fails early if the tag does not match the Cargo version.
4. A pre-release appears under GitHub Releases with
   `OpenRail-windows-x64.zip` and `OpenRail-linux-x64.tar.gz`. Edit the
   release notes and untick "pre-release" when you are happy with it.

Each archive holds the game, the GDExtension library (must stay next to the
executable), `openrail-server`, `server.example.toml`, `LICENSE` and a
bilingual `README.txt` (source: `tools/release-readme.txt`).

## Without a tag

- Run the workflow manually (Actions > Release > Run workflow): both archives
  are built and kept as workflow artifacts for 14 days, no release is made.
- Pull requests touching `client/`, `crates/openrail-gdext/`, `tools/` or the
  workflow run the Windows export as a check, so export breakage shows up
  before tagging.

## Building an export locally (Linux)

```
cargo build --release -p openrail-gdext -p openrail-server
tools/copy-gdext.sh release
tools/setup-godot.sh linux          # Godot 4.4.1 + Linux template into ~/godot-ci
cd client
~/godot-ci/godot --headless --import --path .
mkdir -p build/linux
~/godot-ci/godot --headless --path . --export-release "Linux"
```

`client/build/` is ignored by version control.

## Notes

- Export templates are matched to the Godot version (4.4.1). To upgrade
  Godot, change `ver` in `tools/setup-godot.sh` and the cache keys in
  `release.yml`.
- The Windows job downloads `rcedit` (v2.0.0) so the exe gets its icon and
  version info.
- The 3D assets are stored with Git LFS, hence `lfs: true` on checkout.
