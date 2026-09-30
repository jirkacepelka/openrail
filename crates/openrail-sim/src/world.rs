//! The world state and its tick. Everything here must stay deterministic:
//! fixed-point math only, ordered collections only, randomness only from
//! `World::rng`.

use std::collections::{BTreeMap, VecDeque};

use serde::{Deserialize, Serialize};

use crate::command::{Command, CommandError, PlayerId};
use crate::network::shortest_path_avoiding;
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

/// A track junction or end point. Stations are nodes where trains stop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Node {
    pub pos: Vec2,
    pub owner: PlayerId,
    pub station: bool,
}

/// A straight track segment between two nodes. Each segment is one signal
/// block: at most one train may be on it at a time.
///
/// Signals work as path signals: before a train enters its next block it
/// reserves every block up to its next stop, so two trains never meet
/// head-on between stations. Trains prefer paths that are free right now,
/// so parallel tracks act as passing loops and extra platforms. A single
/// track line with trains in both directions still needs such a loop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub a: NodeId,
    pub b: NodeId,
    pub length: Fixed,
    pub owner: PlayerId,
}

impl Track {
    /// The end a train reaches when driving in the given direction.
    pub fn end(&self, forward: bool) -> NodeId {
        if forward {
            self.b
        } else {
            self.a
        }
    }
}

/// A train. Without a route it shuttles along its track; with a route it
/// drives the network from station to station, in a loop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Train {
    pub track: TrackId,
    /// Distance from node `a`, in metres.
    pub offset: Fixed,
    /// Current speed in m/s, always non-negative.
    pub speed: Fixed,
    /// `true` when heading from `a` to `b`.
    pub forward: bool,
    /// Ticks left to wait at the current stop.
    pub dwell: u32,
    pub owner: PlayerId,
    /// Stations served in order; empty means shuttle mode.
    pub stops: Vec<NodeId>,
    /// Index into `stops` of the station the train is heading for.
    pub next_stop: usize,
    /// Tracks still to drive after the current one.
    pub path: VecDeque<TrackId>,
    /// `true` while held at a red signal.
    pub held: bool,
    /// `true` once every block in `path` is reserved for this train.
    pub reserved: bool,
}

/// How often a train held at a red signal re-plans its path.
const REPLAN_TICKS: u64 = 5 * TICKS_PER_SECOND as u64;

impl Train {
    pub const MAX_SPEED: Fixed = Fixed::from_int(30);
    pub const ACCEL: Fixed = Fixed::from_ratio(1, 1);
    pub const DECEL: Fixed = Fixed::from_ratio(1, 1);
    /// Speed kept while braking, so a train always reaches its stop point.
    pub const CREEP: Fixed = Fixed::from_ratio(1, 2);

    fn remaining(&self, track: &Track) -> Fixed {
        if self.forward {
            track.length - self.offset
        } else {
            self.offset
        }
    }
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

    pub fn train(&self, id: TrainId) -> Option<&Train> {
        self.trains.get(&id)
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

    /// The train occupying a track, if any.
    pub fn occupant(&self, track: TrackId) -> Option<TrainId> {
        self.trains
            .iter()
            .find(|(_, t)| t.track == track)
            .map(|(id, _)| *id)
    }

    /// The train that is on a track or has reserved it, if any.
    pub fn claimant(&self, track: TrackId) -> Option<TrainId> {
        self.trains
            .iter()
            .find(|(_, t)| t.track == track || (t.reserved && t.path.contains(&track)))
            .map(|(id, _)| *id)
    }

    fn claimed_by_other(&self, me: TrainId, track: TrackId) -> bool {
        self.claimant(track).is_some_and(|o| o != me)
    }

    fn alloc_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Validates and applies one player command. A rejected command leaves
    /// the world untouched.
    pub fn apply(&mut self, player: PlayerId, cmd: &Command) -> Result<(), CommandError> {
        match cmd {
            &Command::BuildNode { pos } => {
                let id = NodeId(self.alloc_id());
                self.nodes.insert(
                    id,
                    Node {
                        pos,
                        owner: player,
                        station: false,
                    },
                );
            }
            &Command::BuildTrack { a, b } => {
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
            &Command::BuildStation { node } => {
                let n = self
                    .nodes
                    .get_mut(&node)
                    .ok_or(CommandError::UnknownNode(node))?;
                if n.owner != player {
                    return Err(CommandError::NotOwner);
                }
                n.station = true;
            }
            &Command::SpawnTrain { track } => {
                if !self.tracks.contains_key(&track) {
                    return Err(CommandError::UnknownTrack(track));
                }
                if self.claimant(track).is_some() {
                    return Err(CommandError::TrackOccupied(track));
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
                        stops: Vec::new(),
                        next_stop: 0,
                        path: VecDeque::new(),
                        held: false,
                        reserved: false,
                    },
                );
            }
            Command::SetRoute { train, stops } => {
                let t = self
                    .trains
                    .get(train)
                    .ok_or(CommandError::UnknownTrain(*train))?;
                if t.owner != player {
                    return Err(CommandError::NotOwner);
                }
                for stop in stops {
                    let n = self
                        .nodes
                        .get(stop)
                        .ok_or(CommandError::UnknownNode(*stop))?;
                    if !n.station {
                        return Err(CommandError::NotAStation(*stop));
                    }
                }
                let mut t = t.clone();
                t.stops = stops.clone();
                t.next_stop = 0;
                // Mid-track a train cannot turn around; at rest it may.
                let at_rest = t.speed == Fixed::ZERO;
                self.plan(*train, &mut t, at_rest);
                self.trains.insert(*train, t);
            }
            &Command::RemoveTrain { train } => {
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

    /// Chooses the path to the train's next stop, preferring one that no
    /// other train holds right now. With `may_reverse` the train may also
    /// turn around on its current track if that is shorter.
    fn plan(&self, id: TrainId, train: &mut Train, may_reverse: bool) {
        let free = |t: TrackId| !self.claimed_by_other(id, t);
        if !self.plan_with(train, may_reverse, &free) {
            self.plan_with(train, may_reverse, &|_| true);
        }
    }

    /// Returns `false` when no path exists using only tracks `usable` allows.
    fn plan_with(
        &self,
        train: &mut Train,
        may_reverse: bool,
        usable: &dyn Fn(TrackId) -> bool,
    ) -> bool {
        train.path.clear();
        train.reserved = false;
        let Some(&target) = train.stops.get(train.next_stop) else {
            return true;
        };
        let Some(track) = self.tracks.get(&train.track) else {
            return true;
        };
        let ahead = shortest_path_avoiding(&self.tracks, track.end(train.forward), target, usable)
            .map(|(p, len)| (p, len + train.remaining(track)));
        let behind = if may_reverse {
            shortest_path_avoiding(&self.tracks, track.end(!train.forward), target, usable)
                .map(|(p, len)| (p, len + track.length - train.remaining(track)))
        } else {
            None
        };
        match (ahead, behind) {
            (Some((p, a)), Some((_, b))) if a <= b => train.path = p,
            (_, Some((p, _))) => {
                train.forward = !train.forward;
                train.path = p;
            }
            (Some((p, _)), None) => train.path = p,
            (None, None) => return false,
        }
        true
    }

    /// Advances the simulation by one tick.
    pub fn step(&mut self) {
        let dt = Fixed::from_ratio(1, TICKS_PER_SECOND as i32);
        let ids: Vec<TrainId> = self.trains.keys().copied().collect();
        for id in ids {
            let mut train = self.trains[&id].clone();
            let Some(track) = self.tracks.get(&train.track).cloned() else {
                continue;
            };
            if train.dwell > 0 {
                train.dwell -= 1;
                if train.dwell == 0 {
                    self.plan(id, &mut train, true);
                }
                self.trains.insert(id, train);
                continue;
            }

            // Path signal: green once every block up to the next stop is
            // reserved. A train held at red looks for a free way round
            // every few seconds.
            if train.held && self.tick % REPLAN_TICKS == 0 {
                self.plan(id, &mut train, false);
            }
            if !train.reserved
                && !train.path.is_empty()
                && train.path.iter().all(|&t| !self.claimed_by_other(id, t))
            {
                train.reserved = true;
            }
            let next = train.path.front().copied();
            let red = next.is_some() && !train.reserved;
            let must_stop = next.is_none() || red;
            train.held = red && train.speed == Fixed::ZERO;

            let remaining = train.remaining(&track);
            let braking = train.speed * train.speed / (Fixed::from_int(2) * Train::DECEL);
            train.speed = if must_stop && braking >= remaining {
                (train.speed - Train::DECEL * dt).max(Train::CREEP)
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
                let node = track.end(train.forward);
                if let (false, Some(next)) = (must_stop, next) {
                    // Enter the next block, keeping speed.
                    train.path.pop_front();
                    let nt = &self.tracks[&next];
                    train.track = next;
                    train.forward = nt.a == node;
                    train.offset = if train.forward {
                        Fixed::ZERO
                    } else {
                        nt.length
                    };
                } else if red {
                    train.speed = Fixed::ZERO;
                    train.held = true;
                } else {
                    train.speed = Fixed::ZERO;
                    train.reserved = false;
                    self.arrive(&mut train, node);
                }
            }
            self.trains.insert(id, train);
        }
        self.tick += 1;
    }

    /// A train has stopped at the end of its path at `node`.
    fn arrive(&mut self, train: &mut Train, node: NodeId) {
        let at_stop = train.stops.get(train.next_stop) == Some(&node);
        if at_stop {
            train.next_stop = (train.next_stop + 1) % train.stops.len();
        }
        if at_stop || train.stops.is_empty() {
            if train.stops.is_empty() {
                train.forward = !train.forward;
            }
            // Station stop of 20 to 40 seconds.
            let secs = 20 + self.rng.below(21) as u32;
            train.dwell = secs * TICKS_PER_SECOND;
        } else {
            // No route from here yet: wait, then try again.
            train.dwell = 10 * TICKS_PER_SECOND;
        }
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
