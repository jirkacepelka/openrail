//! Godot 4 GDExtension exposing the OpenRail simulation as `SimWorld`.

mod net;

use godot::prelude::*;
use openrail_sim::{Command, CommandError, Fixed, NodeId, PlayerId, TrackId, TrainId, Vec2, World};

fn vector2(p: Vec2) -> Vector2 {
    Vector2::new(p.x.to_f64_lossy() as f32, p.y.to_f64_lossy() as f32)
}

struct OpenRailExtension;

#[gdextension]
unsafe impl ExtensionLibrary for OpenRailExtension {}

const LOCAL_PLAYER: PlayerId = PlayerId(0);

/// Convert a float coordinate (metres) to fixed point.
///
/// This is the ONLY place floating point values enter the simulation: the
/// client hands over a float, it is truncated to 16.16 fixed point here and
/// from then on the simulation is purely integer-based.
fn fixed_from_f64(v: f64) -> Fixed {
    Fixed::from_bits((v * 65536.0) as i64)
}

/// A world the game renders and picks from.
///
/// A local world (the default) is simulated here: `step` advances it and
/// the `build_*` / `spawn_train` / `set_route` methods apply commands as
/// player 0 right away. A remote view, handed out by `NetClient.world()`,
/// shows the confirmed world of an online game instead: every query works
/// the same, but the view is read-only (`step` does nothing, commands are
/// refused; submit them through `NetClient`) and `balance` is that of the
/// joined player.
#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct SimWorld {
    world: World,
    /// Whose company `balance` shows and who local commands act as.
    player: PlayerId,
    /// Read-only view of a `NetClient`'s world.
    remote: bool,
    last_error: GString,
    error_count: i64,
    base: Base<RefCounted>,
}


#[godot_api]
impl IRefCounted for SimWorld {
    fn init(base: Base<RefCounted>) -> Self {
        SimWorld {
            world: World::new(0),
            player: LOCAL_PLAYER,
            remote: false,
            last_error: GString::new(),
            error_count: 0,
            base,
        }
    }
}

impl SimWorld {
    /// Apply a command as `player` to a local world, remembering the error
    /// text. A remote view refuses every command (submit them through
    /// `NetClient`) without touching the error record.
    fn apply(&mut self, cmd: &Command) -> Result<(), ()> {
        if self.remote {
            godot_warn!("SimWorld: this is a remote view; submit commands through NetClient");
            return Err(());
        }
        let result = self.world.apply(self.player, cmd);
        self.last_error = match &result {
            Ok(()) => GString::new(),
            Err(e) => {
                self.error_count += 1;
                GString::from(e.to_string().as_str())
            }
        };
        result.map_err(|_| ())
    }
}

#[godot_api]
impl SimWorld {
    /// Replace the world with a fresh one created from `seed`.
    #[func]
    fn new_world(&mut self, seed: i64) {
        if self.remote {
            return;
        }
        self.world = World::new(seed as u64);
    }

    #[func]
    fn step(&mut self) {
        if self.remote {
            return; // advanced by NetClient.poll()
        }
        self.world.step();
    }

    /// `true` for a read-only view of an online game (see `NetClient`).
    #[func]
    fn is_remote(&self) -> bool {
        self.remote
    }

    /// The player whose company this world shows: 0 locally, the joined
    /// player's id in an online game.
    #[func]
    fn player_id(&self) -> i64 {
        i64::from(self.player.0)
    }

    #[func]
    fn tick(&self) -> i64 {
        self.world.tick() as i64
    }

    #[func]
    fn state_hash_hex(&self) -> GString {
        GString::from(format!("{:016x}", self.world.state_hash()).as_str())
    }

    /// Build a node at (x, y) metres. Returns the new node id or -1.
    #[func]
    fn build_node(&mut self, x: f64, y: f64) -> i64 {
        let pos = Vec2::new(fixed_from_f64(x), fixed_from_f64(y));
        match self.apply(&Command::BuildNode { pos }) {
            Ok(()) => self
                .world
                .nodes()
                .map(|(id, _)| i64::from(id.0))
                .max()
                .unwrap_or(-1),
            Err(_) => -1,
        }
    }

    /// Build a track between two nodes. Returns the new track id or -1.
    #[func]
    fn build_track(&mut self, a: i64, b: i64) -> i64 {
        let (Ok(a), Ok(b)) = (u32::try_from(a), u32::try_from(b)) else {
            return -1;
        };
        let cmd = Command::BuildTrack {
            a: NodeId(a),
            b: NodeId(b),
        };
        match self.apply(&cmd) {
            Ok(()) => self
                .world
                .tracks()
                .map(|(id, _)| i64::from(id.0))
                .max()
                .unwrap_or(-1),
            Err(_) => -1,
        }
    }

    /// Spawn a train on a track. Returns the new train id or -1.
    #[func]
    fn spawn_train(&mut self, track: i64) -> i64 {
        let Ok(track) = u32::try_from(track) else {
            return -1;
        };
        let cmd = Command::SpawnTrain {
            track: TrackId(track),
        };
        match self.apply(&cmd) {
            Ok(()) => self
                .world
                .trains()
                .map(|(id, _)| i64::from(id.0))
                .max()
                .unwrap_or(-1),
            Err(_) => -1,
        }
    }

    /// Turn a node into a station. Returns `false` if the command was rejected.
    #[func]
    fn build_station(&mut self, node: i64) -> bool {
        let Ok(node) = u32::try_from(node) else {
            return false;
        };
        let cmd = Command::BuildStation { node: NodeId(node) };
        self.apply(&cmd).is_ok()
    }

    /// Send a train around the given station node ids in a loop. Returns
    /// `false` if the command was rejected.
    #[func]
    fn set_route(&mut self, train: i64, stops: PackedInt64Array) -> bool {
        let Ok(train) = u32::try_from(train) else {
            return false;
        };
        let Ok(stops) = stops
            .as_slice()
            .iter()
            .map(|&n| u32::try_from(n).map(NodeId))
            .collect::<Result<Vec<_>, _>>()
        else {
            return false;
        };
        let cmd = Command::SetRoute {
            train: TrainId(train),
            stops,
        };
        self.apply(&cmd).is_ok()
    }

    /// All nodes as `{id, x, y, station}` (rendering and UI only, lossy).
    #[func]
    fn nodes(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        for (id, n) in self.world.nodes() {
            let p = vector2(n.pos);
            out.push(&vdict! {
                "id" => i64::from(id.0),
                "x" => p.x,
                "y" => p.y,
                "station" => n.station,
            });
        }
        out
    }

    /// All tracks as `{id, a, b}` with node ids for `a` and `b`.
    #[func]
    fn tracks(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        for (id, t) in self.world.tracks() {
            out.push(&vdict! {
                "id" => i64::from(id.0),
                "a" => i64::from(t.a.0),
                "b" => i64::from(t.b.0),
            });
        }
        out
    }

    /// All trains as `{id, track, stops, x, y}` where `stops` is a
    /// `PackedInt64Array` of station node ids (empty in shuttle mode).
    #[func]
    fn trains(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        for (id, t) in self.world.trains() {
            let stops: PackedInt64Array = t.stops.iter().map(|s| i64::from(s.0)).collect();
            let p = self
                .world
                .train_position(id)
                .map(vector2)
                .unwrap_or_default();
            out.push(&vdict! {
                "id" => i64::from(id.0),
                "track" => i64::from(t.track.0),
                "stops" => &stops,
                "x" => p.x,
                "y" => p.y,
            });
        }
        out
    }

    /// Id of the node closest to (x, y) within `radius` metres, or -1.
    /// Ties go to the lowest id. Used for UI snapping only.
    #[func]
    fn nearest_node(&self, x: f64, y: f64, radius: f64) -> i64 {
        let mut best: Option<(f64, u32)> = None;
        for (id, n) in self.world.nodes() {
            let dx = n.pos.x.to_f64_lossy() - x;
            let dy = n.pos.y.to_f64_lossy() - y;
            let d = (dx * dx + dy * dy).sqrt();
            if d <= radius && best.map_or(true, |(bd, _)| d < bd) {
                best = Some((d, id.0));
            }
        }
        best.map_or(-1, |(_, id)| i64::from(id))
    }

    /// Track end points in metres, two entries per track (rendering only).
    #[func]
    fn track_segments(&self) -> PackedVector2Array {
        let pos: std::collections::BTreeMap<NodeId, Vec2> =
            self.world.nodes().map(|(id, n)| (id, n.pos)).collect();
        let mut out = PackedVector2Array::new();
        for (_, t) in self.world.tracks() {
            out.push(vector2(pos[&t.a]));
            out.push(vector2(pos[&t.b]));
        }
        out
    }

    /// The player's (see `player_id`) balance in whole currency units.
    #[func]
    fn balance(&self) -> i64 {
        self.world.balance(self.player)
    }

    /// Today's in-game date as `YYYY-MM-DD`.
    #[func]
    fn date_string(&self) -> GString {
        GString::from(self.world.date().to_string().as_str())
    }

    /// Passengers waiting at a station node, all destinations together.
    #[func]
    fn station_waiting(&self, node: i64) -> i64 {
        u32::try_from(node).map_or(0, |n| i64::from(self.world.waiting_total(NodeId(n))))
    }

    /// Passengers on board a train.
    #[func]
    fn train_load(&self, train: i64) -> i64 {
        u32::try_from(train).map_or(0, |t| i64::from(self.world.train_load(TrainId(t))))
    }

    /// Town centres in metres, in town id order (rendering only, lossy).
    #[func]
    fn town_positions(&self) -> PackedVector2Array {
        let mut out = PackedVector2Array::new();
        for (_, t) in self.world.towns() {
            out.push(vector2(t.pos));
        }
        out
    }

    /// Town names, in the same order as `town_positions`.
    #[func]
    fn town_names(&self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for (_, t) in self.world.towns() {
            out.push(t.name().as_str());
        }
        out
    }

    /// Town populations, in the same order as `town_positions`.
    #[func]
    fn town_populations(&self) -> PackedInt64Array {
        let mut out = PackedInt64Array::new();
        for (_, t) in self.world.towns() {
            out.push(i64::from(t.population));
        }
        out
    }

    /// Current train positions in metres (rendering only, lossy).
    #[func]
    fn train_positions(&self) -> PackedVector2Array {
        let mut out = PackedVector2Array::new();
        let ids: Vec<TrainId> = self.world.trains().map(|(id, _)| id).collect();
        for id in ids {
            if let Some(p) = self.world.train_position(id) {
                out.push(vector2(p));
            }
        }
        out
    }

    /// Found a town at (x, y) metres. Returns `false` if it was rejected.
    #[func]
    fn found_town(&mut self, x: f64, y: f64, population: i64, name_seed: i64) -> bool {
        let (Ok(population), Ok(name_seed)) = (u32::try_from(population), u32::try_from(name_seed))
        else {
            return false;
        };
        let cmd = Command::FoundTown {
            pos: Vec2::new(fixed_from_f64(x), fixed_from_f64(y)),
            name_seed,
            population,
        };
        self.apply(&cmd).is_ok()
    }

    /// Passengers one train carries (economy rule).
    #[func]
    fn train_capacity(&self) -> i64 {
        i64::from(self.world.rules().train_capacity)
    }

    /// English text of the error of the last rejected build command, or an
    /// empty string if the last command succeeded.
    #[func]
    fn last_error(&self) -> GString {
        self.last_error.clone()
    }

    /// Number of commands rejected so far (lets the UI notice a new failure).
    #[func]
    fn error_count(&self) -> i64 {
        self.error_count
    }

    /// `true` if the last rejected command failed for lack of money.
    #[func]
    fn last_error_is_funds(&self) -> bool {
        self.last_error.to_string() == CommandError::InsufficientFunds.to_string()
    }
}
