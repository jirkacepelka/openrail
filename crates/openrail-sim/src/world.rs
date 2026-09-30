//! The world state and its tick. Everything here must stay deterministic:
//! fixed-point math only, ordered collections only, randomness only from
//! `World::rng`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::command::{Command, CommandError, PlayerId};
use crate::{Fixed, SimRng, TICKS_PER_SECOND};

macro_rules! id_type {
    ($name:ident) => {
        #[derive(
            Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
        )]
        pub struct $name(pub u32);
    };
}

id_type!(NodeId);
id_type!(TrackId);
id_type!(TrainId);

/// A point on the map in metres.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Vec2 {
    pub x: Fixed,
    pub y: Fixed,
}

impl Vec2 {
    pub const fn new(x: Fixed, y: Fixed) -> Self {
        Vec2 { x, y }
    }

    pub fn distance(self, other: Vec2) -> Fixed {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        (dx * dx + dy * dy).sqrt()
    }

    pub fn lerp(self, other: Vec2, t: Fixed) -> Vec2 {
        Vec2::new(
            self.x + (other.x - self.x) * t,
            self.y + (other.y - self.y) * t,
        )
    }
}

/// A track junction or end point.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Node {
    pub pos: Vec2,
    pub owner: PlayerId,
}

/// A straight track segment between two nodes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub a: NodeId,
    pub b: NodeId,
    pub length: Fixed,
    pub owner: PlayerId,
}

/// A train shuttling along one track segment. Routing across the network
/// arrives in phase 1; for now it runs end to end and waits at each end.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Train {
    pub track: TrackId,
    /// Distance from node `a`, in metres.
    pub offset: Fixed,
    /// Current speed in m/s, always non-negative.
    pub speed: Fixed,
    /// `true` when heading from `a` to `b`.
    pub forward: bool,
    /// Ticks left to wait at the current end.
    pub dwell: u32,
    pub owner: PlayerId,
}

impl Train {
    pub const MAX_SPEED: Fixed = Fixed::from_int(30);
    pub const ACCEL: Fixed = Fixed::from_ratio(1, 1);
    pub const DECEL: Fixed = Fixed::from_ratio(1, 1);
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct World {
    tick: u64,
    rng: SimRng,
    next_id: u32,
    nodes: BTreeMap<NodeId, Node>,
    tracks: BTreeMap<TrackId, Track>,
    trains: BTreeMap<TrainId, Train>,
}

#[derive(Debug)]
pub struct LoadError(postcard::Error);

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid save data: {}", self.0)
    }
}

impl std::error::Error for LoadError {}

impl World {
    pub fn new(seed: u64) -> Self {
        World {
            tick: 0,
            rng: SimRng::new(seed),
            next_id: 1,
            nodes: BTreeMap::new(),
            tracks: BTreeMap::new(),
            trains: BTreeMap::new(),
        }
    }

    /// Number of ticks simulated so far.
    pub fn tick(&self) -> u64 {
        self.tick
    }

    pub fn nodes(&self) -> impl Iterator<Item = (NodeId, &Node)> {
        self.nodes.iter().map(|(id, n)| (*id, n))
    }

    pub fn tracks(&self) -> impl Iterator<Item = (TrackId, &Track)> {
        self.tracks.iter().map(|(id, t)| (*id, t))
    }

    pub fn trains(&self) -> impl Iterator<Item = (TrainId, &Train)> {
        self.trains.iter().map(|(id, t)| (*id, t))
    }

    /// Where a train is on the map, for rendering and UI.
    pub fn train_position(&self, id: TrainId) -> Option<Vec2> {
        let train = self.trains.get(&id)?;
        let track = self.tracks.get(&train.track)?;
        let a = self.nodes.get(&track.a)?.pos;
        let b = self.nodes.get(&track.b)?.pos;
        if track.length == Fixed::ZERO {
            return Some(a);
        }
        Some(a.lerp(b, train.offset / track.length))
    }

    fn alloc_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Validates and applies one player command. A rejected command leaves
    /// the world untouched.
    pub fn apply(&mut self, player: PlayerId, cmd: &Command) -> Result<(), CommandError> {
        match *cmd {
            Command::BuildNode { pos } => {
                let id = NodeId(self.alloc_id());
                self.nodes.insert(id, Node { pos, owner: player });
            }
            Command::BuildTrack { a, b } => {
                if a == b {
                    return Err(CommandError::DegenerateTrack);
                }
                let pa = self.nodes.get(&a).ok_or(CommandError::UnknownNode(a))?.pos;
                let pb = self.nodes.get(&b).ok_or(CommandError::UnknownNode(b))?.pos;
                let length = pa.distance(pb);
                if length == Fixed::ZERO {
                    return Err(CommandError::DegenerateTrack);
                }
                let id = TrackId(self.alloc_id());
                self.tracks.insert(
                    id,
                    Track {
                        a,
                        b,
                        length,
                        owner: player,
                    },
                );
            }
            Command::SpawnTrain { track } => {
                if !self.tracks.contains_key(&track) {
                    return Err(CommandError::UnknownTrack(track));
                }
                let id = TrainId(self.alloc_id());
                self.trains.insert(
                    id,
                    Train {
                        track,
                        offset: Fixed::ZERO,
                        speed: Fixed::ZERO,
                        forward: true,
                        dwell: 0,
                        owner: player,
                    },
                );
            }
            Command::RemoveTrain { train } => {
                let t = self
                    .trains
                    .get(&train)
                    .ok_or(CommandError::UnknownTrain(train))?;
                if t.owner != player {
                    return Err(CommandError::NotOwner);
                }
                self.trains.remove(&train);
            }
        }
        Ok(())
    }

    /// Advances the simulation by one tick.
    pub fn step(&mut self) {
        let dt = Fixed::from_ratio(1, TICKS_PER_SECOND as i32);
        for train in self.trains.values_mut() {
            let Some(track) = self.tracks.get(&train.track) else {
                continue;
            };
            if train.dwell > 0 {
                train.dwell -= 1;
                continue;
            }
            let remaining = if train.forward {
                track.length - train.offset
            } else {
                train.offset
            };
            let braking = train.speed * train.speed / (Fixed::from_int(2) * Train::DECEL);
            train.speed = if braking >= remaining {
                (train.speed - Train::DECEL * dt).max(Fixed::from_ratio(1, 2))
            } else {
                (train.speed + Train::ACCEL * dt).min(Train::MAX_SPEED)
            };
            let moved = (train.speed * dt).min(remaining);
            if train.forward {
                train.offset += moved;
            } else {
                train.offset -= moved;
            }
            if moved == remaining {
                train.speed = Fixed::ZERO;
                train.forward = !train.forward;
                // Station stop of 20 to 40 seconds.
                let secs = 20 + self.rng.below(21) as u32;
                train.dwell = secs * TICKS_PER_SECOND;
            }
        }
        self.tick += 1;
    }

    /// Serializes the whole world. Loading the result reproduces the world
    /// exactly, including its random state.
    pub fn save(&self) -> Vec<u8> {
        postcard::to_allocvec(self).expect("world serialization cannot fail")
    }

    pub fn load(bytes: &[u8]) -> Result<World, LoadError> {
        postcard::from_bytes(bytes).map_err(LoadError)
    }

    /// FNV-1a hash of the serialized world. Clients and server compare it
    /// every few ticks to detect a desync.
    pub fn state_hash(&self) -> u64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in self.save() {
            h ^= byte as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        h
    }
}
