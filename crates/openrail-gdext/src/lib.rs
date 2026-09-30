//! Godot 4 GDExtension exposing the OpenRail simulation as `SimWorld`.

use godot::prelude::*;
use openrail_sim::{Command, Fixed, NodeId, PlayerId, TrackId, TrainId, Vec2, World};

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

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct SimWorld {
    world: World,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for SimWorld {
    fn init(base: Base<RefCounted>) -> Self {
        SimWorld {
            world: World::new(0),
            base,
        }
    }
}

#[godot_api]
impl SimWorld {
    /// Replace the world with a fresh one created from `seed`.
    #[func]
    fn new_world(&mut self, seed: i64) {
        self.world = World::new(seed as u64);
    }

    #[func]
    fn step(&mut self) {
        self.world.step();
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
        match self.world.apply(LOCAL_PLAYER, &Command::BuildNode { pos }) {
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
        match self.world.apply(LOCAL_PLAYER, &cmd) {
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
        match self.world.apply(LOCAL_PLAYER, &cmd) {
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
        self.world.apply(LOCAL_PLAYER, &cmd).is_ok()
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
        self.world.apply(LOCAL_PLAYER, &cmd).is_ok()
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
}
