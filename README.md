# OpenRail

**Česky:** OpenRail je open-source (MIT) dopravní tycoon hra. Klient je ve Godotu 4,
simulační jádro je deterministické a napsané v Rustu; sdílí ho klient i dedikovaný
server (selfhost). Kód je pod licencí MIT, assety pod CC BY-SA 4.0. Sestavení a
spuštění najdete níže.

OpenRail is an open-source transport tycoon game: a Godot 4 client on top of a
deterministic Rust simulation core that is shared with a selfhost dedicated server.

## Repository layout

- `crates/openrail-sim` - deterministic simulation core (fixed-point, no floats).
- `crates/openrail-server` - headless dedicated server with a small HTTP admin API.
- `crates/openrail-gdext` - Godot GDExtension exposing the simulation as `SimWorld`.
- `client/` - the Godot 4.4+ project.

## Building

```sh
cargo build --workspace          # sim, server, gdext
cargo test --workspace --exclude openrail-gdext
```

### Server

```sh
cp server.example.toml server.toml
cargo run -p openrail-server -- --config server.toml
curl localhost:7878/health
curl localhost:7878/status
```

### Docker

```sh
docker compose up --build
```

The world is saved to the `/data` volume. Player command networking is not
implemented yet (planned for phase 3).

### Client

```sh
cargo build -p openrail-gdext
```

Then open `client/project.godot` in Godot 4.4+ and press Play. The extension is
loaded from `target/debug` (or `target/release`).

## License

Code: MIT (see `LICENSE`). Assets: CC BY-SA 4.0.
