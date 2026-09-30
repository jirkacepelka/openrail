//! `NetClient`: joins a dedicated server and plays on it (lockstep).
//!
//! A thin Godot wrapper around [`openrail_net::remote::RemoteClient`]. The
//! QUIC connection lives on a background thread; everything here runs on
//! Godot's main thread and never blocks:
//!
//! ```gdscript
//! var net := NetClient.new()
//! var err := net.connect_to_server("example.org", 7878, "", "ann", fingerprint)
//! # every frame:
//! for ev in net.poll(50):
//!     match ev["type"]:
//!         "joined": ...
//!         "command_result": ...
//! var world: SimWorld = net.world()  # render and pick from this
//! var seq := net.submit_build_node(100.0, 200.0)
//! ```
//!
//! `world()` is a read-only `SimWorld` view with the same queries as a
//! local world. `poll` copies the confirmed world into it whenever a tick
//! was simulated, so it always shows a consistent confirmed state and
//! `balance` shows the joined player's company.
//!
//! Events returned by `poll` (dictionaries with a `type` key):
//!
//! | type | other keys |
//! | --- | --- |
//! | `connected` | (QUIC is up, waiting to be let in) |
//! | `joined` | `player_id`, `tick` |
//! | `failed` | `reason` (could not join: unreachable, certificate, refused) |
//! | `disconnected` | `reason` (kicked or connection lost after joining) |
//! | `command_result` | `seq`, `ok`, `id` (created node / track / train, or -1), `error` |
//! | `player_joined` | `player_id`, `name` |
//! | `player_left` | `player_id` |
//! | `chat` | `player_id`, `text` |
//! | `desync` | `tick` |
//! | `resynced` | `tick` |
//! | `world_changed` | (nodes, tracks, stations, trains or routes changed) |
//!
//! A successful `command_result` arrives only once `world()` shows the
//! change, so its `id` can be used right away.

use godot::prelude::*;
use openrail_net::remote::{verification_from_str, RemoteClient, RemoteEvent, RemoteState};
use openrail_sim::{Command, NodeId, PlayerId, TrackId, TrainId, Vec2};

use crate::{fixed_from_f64, SimWorld};

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct NetClient {
    remote: Option<RemoteClient>,
    view: Gd<SimWorld>,
    /// Tick of the world last copied into `view`.
    synced_tick: Option<u64>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for NetClient {
    fn init(base: Base<RefCounted>) -> Self {
        let mut view = SimWorld::new_gd();
        view.bind_mut().remote = true;
        NetClient {
            remote: None,
            view,
            synced_tick: None,
            base,
        }
    }
}

fn id_or_none(v: i64) -> Option<u32> {
    u32::try_from(v).ok()
}

fn event_dict(ev: RemoteEvent) -> VarDictionary {
    match ev {
        RemoteEvent::Connected => vdict! { "type" => "connected" },
        RemoteEvent::Joined { player_id, tick } => vdict! {
            "type" => "joined",
            "player_id" => i64::from(player_id.0),
            "tick" => tick as i64,
        },
        RemoteEvent::Failed { reason } => vdict! { "type" => "failed", "reason" => reason },
        RemoteEvent::Disconnected { reason } => {
            vdict! { "type" => "disconnected", "reason" => reason }
        }
        RemoteEvent::CommandDone { seq, result } => {
            let (ok, id, error) = match result {
                Ok(id) => (true, id.map_or(-1, i64::from), String::new()),
                Err(e) => (false, -1, e),
            };
            vdict! {
                "type" => "command_result",
                "seq" => i64::from(seq),
                "ok" => ok,
                "id" => id,
                "error" => error,
            }
        }
        RemoteEvent::PlayerJoined(info) => vdict! {
            "type" => "player_joined",
            "player_id" => i64::from(info.id.0),
            "name" => info.name,
        },
        RemoteEvent::PlayerLeft { player_id } => vdict! {
            "type" => "player_left",
            "player_id" => i64::from(player_id.0),
        },
        RemoteEvent::Chat { from, text } => vdict! {
            "type" => "chat",
            "player_id" => i64::from(from.0),
            "text" => text,
        },
        RemoteEvent::Desync { tick } => vdict! { "type" => "desync", "tick" => tick as i64 },
        RemoteEvent::Resynced { tick } => vdict! { "type" => "resynced", "tick" => tick as i64 },
        RemoteEvent::WorldChanged => vdict! { "type" => "world_changed" },
    }
}

impl NetClient {
    fn submit(&mut self, cmd: Command) -> i64 {
        self.remote
            .as_mut()
            .and_then(|r| r.submit(cmd))
            .map_or(-1, i64::from)
    }

    /// Copies the confirmed world into the view when it moved on.
    fn sync_view(&mut self, force: bool) {
        let Some(remote) = &self.remote else {
            return;
        };
        let Some(world) = remote.world() else {
            return;
        };
        if !force && self.synced_tick == Some(world.tick()) {
            return;
        }
        self.synced_tick = Some(world.tick());
        let mut view = self.view.bind_mut();
        view.world.clone_from(world);
        view.player = remote.player_id().unwrap_or(PlayerId(0));
        view.terrain_seed = remote.terrain_seed();
    }
}

#[godot_api]
impl NetClient {
    /// Starts joining a server in the background; returns at once with ""
    /// or an error message (bad port or fingerprint). `fingerprint` is the
    /// server certificate's SHA-256 (64 hex digits, `:` allowed) from the
    /// server log or `/status`; pass "" to skip the check (development
    /// only: anyone on the path could impersonate the server). An empty
    /// `password` sends none. Any previous connection is left first.
    #[func]
    fn connect_to_server(
        &mut self,
        address: GString,
        port: i64,
        password: GString,
        player_name: GString,
        fingerprint: GString,
    ) -> GString {
        self.leave();
        let Some(port) = u16::try_from(port).ok().filter(|p| *p > 0) else {
            return "invalid port".into();
        };
        let verification = match verification_from_str(&fingerprint.to_string()) {
            Ok(v) => v,
            Err(e) => return GString::from(e.to_string().as_str()),
        };
        let password = password.to_string();
        let password = (!password.is_empty()).then_some(password);
        match RemoteClient::connect(
            &address.to_string(),
            port,
            verification,
            &player_name.to_string(),
            password,
        ) {
            Ok(r) => {
                self.remote = Some(r);
                self.synced_tick = None;
                GString::new()
            }
            Err(e) => GString::from(e.to_string().as_str()),
        }
    }

    /// Handles what arrived, simulates up to `max_ticks` confirmed ticks,
    /// sends what is due and returns the events since the last call (see
    /// the table in the class docs). Call once per frame.
    #[func]
    fn poll(&mut self, max_ticks: i64) -> Array<VarDictionary> {
        let mut out = Array::new();
        let Some(remote) = self.remote.as_mut() else {
            return out;
        };
        let events = remote.poll(max_ticks.clamp(1, 100_000) as usize);
        let force = events
            .iter()
            .any(|e| matches!(e, RemoteEvent::Joined { .. } | RemoteEvent::Resynced { .. }));
        self.sync_view(force);
        for ev in events {
            out.push(&event_dict(ev));
        }
        out
    }

    /// Leaves the game. Commands still in flight are not reported. The
    /// last world stays visible in `world()`.
    #[func]
    fn leave(&mut self) {
        if let Some(r) = self.remote.as_mut() {
            r.leave();
        }
    }

    /// "idle" (never connected), "connecting", "joining", "playing" or
    /// "closed".
    #[func]
    fn state(&self) -> GString {
        self.remote
            .as_ref()
            .map_or("idle", |r| r.state().as_str())
            .into()
    }

    #[func]
    fn is_playing(&self) -> bool {
        self.remote
            .as_ref()
            .is_some_and(|r| r.state() == RemoteState::Playing)
    }

    /// One line describing the connection, for the UI.
    #[func]
    fn status_text(&self) -> GString {
        self.remote
            .as_ref()
            .map_or("Not connected", |r| r.status())
            .into()
    }

    /// Our player id once joined, else -1.
    #[func]
    fn player_id(&self) -> i64 {
        self.remote
            .as_ref()
            .and_then(RemoteClient::player_id)
            .map_or(-1, |p| i64::from(p.0))
    }

    /// Everyone who has played on the server as `{id, name, connected}`.
    #[func]
    fn players(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        if let Some(r) = &self.remote {
            for p in r.players() {
                out.push(&vdict! {
                    "id" => i64::from(p.id.0),
                    "name" => p.name.as_str(),
                    "connected" => p.connected,
                });
            }
        }
        out
    }

    /// Confirmed ticks received but not simulated yet.
    #[func]
    fn backlog(&self) -> i64 {
        self.remote.as_ref().map_or(0, |r| r.backlog() as i64)
    }

    /// The read-only view of the confirmed world (always the same object).
    #[func]
    fn world(&self) -> Gd<SimWorld> {
        self.view.clone()
    }

    // Commands. Each returns the sequence number its `command_result`
    // event carries, or -1 if it could not be sent (closed, bad id).

    #[func]
    fn submit_build_node(&mut self, x: f64, y: f64) -> i64 {
        let pos = Vec2::new(fixed_from_f64(x), fixed_from_f64(y));
        self.submit(Command::BuildNode { pos })
    }

    #[func]
    fn submit_build_track(&mut self, a: i64, b: i64) -> i64 {
        let (Some(a), Some(b)) = (id_or_none(a), id_or_none(b)) else {
            return -1;
        };
        self.submit(Command::BuildTrack {
            a: NodeId(a),
            b: NodeId(b),
        })
    }

    #[func]
    fn submit_build_station(&mut self, node: i64) -> i64 {
        let Some(node) = id_or_none(node) else {
            return -1;
        };
        self.submit(Command::BuildStation { node: NodeId(node) })
    }

    #[func]
    fn submit_spawn_train(&mut self, track: i64) -> i64 {
        let Some(track) = id_or_none(track) else {
            return -1;
        };
        self.submit(Command::SpawnTrain {
            track: TrackId(track),
        })
    }

    #[func]
    fn submit_set_route(&mut self, train: i64, stops: PackedInt64Array) -> i64 {
        let Some(train) = id_or_none(train) else {
            return -1;
        };
        let Some(stops) = stops
            .as_slice()
            .iter()
            .map(|&n| id_or_none(n).map(NodeId))
            .collect::<Option<Vec<_>>>()
        else {
            return -1;
        };
        self.submit(Command::SetRoute {
            train: TrainId(train),
            stops,
        })
    }

    #[func]
    fn submit_remove_train(&mut self, train: i64) -> i64 {
        let Some(train) = id_or_none(train) else {
            return -1;
        };
        self.submit(Command::RemoveTrain {
            train: TrainId(train),
        })
    }

    #[func]
    fn send_chat(&mut self, text: GString) {
        if let Some(r) = self.remote.as_mut() {
            r.chat(&text.to_string());
        }
    }
}
