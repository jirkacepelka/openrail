//! Deterministic simulation core for OpenRail.
//!
//! The client (through GDExtension) and the dedicated server run this same
//! crate. Given the same seed and the same commands, every machine reaches
//! the same state, so multiplayer only needs to send commands.

pub mod command;
pub mod fixed;
pub mod network;
pub mod replay;
pub mod rng;
pub mod world;

pub use command::{Command, CommandError, PlayerId};
pub use fixed::Fixed;
pub use replay::{Replay, ScheduledCommand};
pub use rng::SimRng;
pub use world::{LoadError, Node, NodeId, Track, TrackId, Train, TrainId, Vec2, World};

/// Simulation rate. Rendering interpolates between ticks.
pub const TICKS_PER_SECOND: u32 = 10;
