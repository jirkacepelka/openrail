//! Player commands: the only way anything outside the simulation changes
//! the world. In multiplayer, commands are what travels over the network.

use serde::{Deserialize, Serialize};

use crate::world::{NodeId, TrackId, TrainId, Vec2};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct PlayerId(pub u16);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Command {
    BuildNode { pos: Vec2 },
    BuildTrack { a: NodeId, b: NodeId },
    SpawnTrain { track: TrackId },
    RemoveTrain { train: TrainId },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandError {
    UnknownNode(NodeId),
    UnknownTrack(TrackId),
    UnknownTrain(TrainId),
    DegenerateTrack,
    NotOwner,
}

impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CommandError::UnknownNode(id) => write!(f, "node {} does not exist", id.0),
            CommandError::UnknownTrack(id) => write!(f, "track {} does not exist", id.0),
            CommandError::UnknownTrain(id) => write!(f, "train {} does not exist", id.0),
            CommandError::DegenerateTrack => write!(f, "track must join two distinct points"),
            CommandError::NotOwner => write!(f, "that belongs to another player"),
        }
    }
}

impl std::error::Error for CommandError {}
