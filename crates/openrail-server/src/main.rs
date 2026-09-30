//! OpenRail dedicated server.
//!
//! Runs the authoritative deterministic simulation headlessly, hosts
//! lockstep multiplayer over QUIC (see `openrail-net`) and exposes a tiny
//! HTTP admin API (`/health`, `/status`).

mod config;

use std::{
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{extract::State, routing::get, Json, Router};
use config::Config;
use openrail_net::{
    quic::{run_host, server_endpoint, ServerIdentity},
    LockstepHost,
};
use openrail_sim::{PlayerId, World, TICKS_PER_SECOND};
use tracing::{error, info, warn};

#[derive(Clone)]
struct AppState {
    host: Arc<Mutex<LockstepHost>>,
    fingerprint: String,
}

fn parse_config_path() -> String {
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--config" {
            if let Some(p) = args.next() {
                return p;
            }
        } else if let Some(p) = a.strip_prefix("--config=") {
            return p.to_string();
        }
    }
    "server.toml".to_string()
}

fn load_config(path: &str) -> Result<Config, String> {
    if !Path::new(path).exists() {
        warn!("config file {path} not found, using defaults");
        return Ok(Config::default());
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
    toml::from_str(&text).map_err(|e| format!("parsing {path}: {e}"))
}

fn write_atomic(path: &str, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

/// Known players live next to the world save, so returning players get
/// their old id back.
fn roster_path(cfg: &Config) -> String {
    format!("{}.players.json", cfg.save_path)
}

fn save_all(host: &LockstepHost, cfg: &Config) -> std::io::Result<()> {
    write_atomic(&cfg.save_path, &host.world().save())?;
    let roster: Vec<(u16, String)> = host
        .roster()
        .into_iter()
        .map(|(id, name)| (id.0, name))
        .collect();
    let json = serde_json::to_vec_pretty(&roster).expect("roster serializes");
    write_atomic(&roster_path(cfg), &json)
}

fn load_world(cfg: &Config) -> Result<World, String> {
    if Path::new(&cfg.save_path).exists() {
        let bytes = std::fs::read(&cfg.save_path).map_err(|e| e.to_string())?;
        let w = World::load(&bytes).map_err(|e| e.to_string())?;
        info!("loaded world from {} at tick {}", cfg.save_path, w.tick());
        Ok(w)
    } else {
        info!("starting new world with seed {}", cfg.seed);
        Ok(World::new(cfg.seed))
    }
}

fn load_roster(cfg: &Config) -> Result<Vec<(PlayerId, String)>, String> {
    let path = roster_path(cfg);
    if !Path::new(&path).exists() {
        return Ok(Vec::new());
    }
    let text = std::fs::read(&path).map_err(|e| format!("reading {path}: {e}"))?;
    let roster: Vec<(u16, String)> =
        serde_json::from_slice(&text).map_err(|e| format!("parsing {path}: {e}"))?;
    Ok(roster
        .into_iter()
        .map(|(id, name)| (PlayerId(id), name))
        .collect())
}

async fn status(State(app): State<AppState>) -> Json<serde_json::Value> {
    let h = app.host.lock().unwrap();
    let w = h.world();
    let players: Vec<serde_json::Value> = h
        .players()
        .into_iter()
        .map(|p| {
            serde_json::json!({
                "id": p.id.0,
                "name": p.name,
                "connected": p.connected,
                "desyncs": p.desyncs,
            })
        })
        .collect();
    Json(serde_json::json!({
        "tick": w.tick(),
        "state_hash": format!("{:016x}", w.state_hash()),
        "nodes": w.nodes().count(),
        "tracks": w.tracks().count(),
        "trains": w.trains().count(),
        "protocol_version": openrail_net::PROTOCOL_VERSION,
        "cert_fingerprint": app.fingerprint,
        "players": players,
    }))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    if let Err(e) = run().await {
        error!("fatal: {e}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let cfg = load_config(&parse_config_path())?;
    let mut host = LockstepHost::new(load_world(&cfg)?, cfg.host_config());
    host.restore_roster(load_roster(&cfg)?);
    let host = Arc::new(Mutex::new(host));

    let identity =
        ServerIdentity::load_or_generate(Path::new(&cfg.cert_path), Path::new(&cfg.key_path))
            .map_err(|e| e.to_string())?;
    let fingerprint = identity.fingerprint().to_string();
    let game_addr: SocketAddr = cfg
        .game_bind
        .parse()
        .map_err(|e| format!("game_bind {}: {e}", cfg.game_bind))?;
    let endpoint = server_endpoint(game_addr, &identity).map_err(|e| e.to_string())?;
    info!("game server (QUIC) listening on udp {game_addr}");
    info!("certificate fingerprint {fingerprint}");
    if cfg.password.as_deref().is_some_and(|p| !p.is_empty()) {
        info!("password required to join");
    }

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/status", get(status))
        .with_state(AppState {
            host: host.clone(),
            fingerprint,
        });
    let listener = tokio::net::TcpListener::bind(&cfg.bind)
        .await
        .map_err(|e| format!("binding {}: {e}", cfg.bind))?;
    info!("admin API listening on tcp {}", cfg.bind);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            error!("http server error: {e}");
        }
    });

    let log_every = u64::from(TICKS_PER_SECOND) * 10;
    let autosave = cfg.autosave_ticks.max(1);
    let on_tick = |h: &LockstepHost| {
        let w = h.world();
        let tick = w.tick();
        if tick % log_every == 0 {
            info!("tick {tick} hash {:016x}", w.state_hash());
        }
        if tick % autosave == 0 {
            match save_all(h, &cfg) {
                Ok(()) => info!("autosaved at tick {tick}"),
                Err(e) => error!("autosave failed: {e}"),
            }
        }
    };
    let shutdown = async {
        let _ = tokio::signal::ctrl_c().await;
        info!("shutdown requested");
    };
    run_host(
        endpoint,
        host.clone(),
        Duration::from_millis(1000 / u64::from(TICKS_PER_SECOND)),
        on_tick,
        shutdown,
    )
    .await;

    let h = host.lock().unwrap();
    save_all(&h, &cfg).map_err(|e| format!("final save failed: {e}"))?;
    info!("final save at tick {} done", h.world().tick());
    Ok(())
}
