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
- `crates/openrail-net` - lockstep multiplayer protocol, host/client state machines, QUIC transport.
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
curl localhost:7878/status   # tick, hash, players, certificate fingerprint
```

Multiplayer is deterministic lockstep (`crates/openrail-net`): only player
commands travel over the network. The server runs the authoritative world,
applies each command on it, and broadcasts per tick the commands that
succeeded; every client applies the same commands and reaches the same state.
State hashes are compared every `hash_interval_ticks`, and a client that has
drifted gets a fresh snapshot. Players can join a running game at any time
(they receive a snapshot) and get their old player id back when they
reconnect with the same name.

Game traffic is QUIC on UDP `game_bind` (default port 7878, next to the TCP
admin API). On first start the server creates a self-signed certificate
(`cert_path`, `key_path`) and logs its SHA-256 fingerprint; keep these files
so the fingerprint stays the same. Clients pin that fingerprint, which
protects against anyone impersonating the server. The insecure mode that
accepts any certificate is for development only: traffic is encrypted but
not authenticated, so the password could be intercepted. Set `password` in
`server.toml` to require one.

Headless test client:

```sh
cargo run -p openrail-net --example bot -- 127.0.0.1:7878 --fingerprint <hex> [--password pw]
cargo run -p openrail-net --example bot -- 127.0.0.1:7878 --insecure   # dev only
```

### Docker

```sh
docker compose up --build
```

The world, the player list and the certificate are saved to the `/data`
volume. Publish both `7878/tcp` (admin) and `7878/udp` (game).

### Client

```sh
cargo build -p openrail-gdext
```

Then open `client/project.godot` in Godot 4.4+ and press Play. The extension is
loaded from `target/debug` (or `target/release`).

The client's painterly look (shaders, lighting, post-process) lives in
`client/art/`; see [docs/art-style.md](docs/art-style.md) for the style guide.

## License

Code: MIT (see `LICENSE`). Assets: CC BY-SA 4.0.
