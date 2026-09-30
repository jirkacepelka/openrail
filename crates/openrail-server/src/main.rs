//! OpenRail dedicated server.
//!
//! Runs the deterministic simulation headlessly and exposes a tiny HTTP admin
//! API (`/health`, `/status`). Networking of player commands is NOT
//! implemented yet; it is planned for phase 3.

mod config;

use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{extract::State, routing::get, Json, Router};
use config::Config;
use openrail_sim::{World, TICKS_PER_SECOND};
use tracing::{error, info, warn};

type Shared = Arc<Mutex<World>>;

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

fn save_atomic(world: &World, path: &str) -> std::io::Result<()> {
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, world.save())?;
    std::fs::rename(&tmp, path)
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

async fn status(State(world): State<Shared>) -> Json<serde_json::Value> {
    let w = world.lock().unwrap();
    Json(serde_json::json!({
        "tick": w.tick(),
        "state_hash": format!("{:016x}", w.state_hash()),
        "nodes": w.nodes().count(),
        "tracks": w.tracks().count(),
        "trains": w.trains().count(),
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
    let world: Shared = Arc::new(Mutex::new(load_world(&cfg)?));

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/status", get(status))
        .with_state(world.clone());
    let listener = tokio::net::TcpListener::bind(&cfg.bind)
        .await
        .map_err(|e| format!("binding {}: {e}", cfg.bind))?;
    info!("admin API listening on {}", cfg.bind);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            error!("http server error: {e}");
        }
    });

    let mut interval =
        tokio::time::interval(Duration::from_millis(1000 / u64::from(TICKS_PER_SECOND)));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let log_every = u64::from(TICKS_PER_SECOND) * 10;
    let autosave = cfg.autosave_ticks.max(1);
    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let mut w = world.lock().unwrap();
                w.step();
                let tick = w.tick();
                if tick % log_every == 0 {
                    info!("tick {tick} hash {:016x}", w.state_hash());
                }
                if tick % autosave == 0 {
                    match save_atomic(&w, &cfg.save_path) {
                        Ok(()) => info!("autosaved at tick {tick}"),
                        Err(e) => error!("autosave failed: {e}"),
                    }
                }
            }
            _ = &mut ctrl_c => {
                info!("shutdown requested");
                break;
            }
        }
    }

    let w = world.lock().unwrap();
    save_atomic(&w, &cfg.save_path).map_err(|e| format!("final save failed: {e}"))?;
    info!("final save at tick {} done", w.tick());
    Ok(())
}
