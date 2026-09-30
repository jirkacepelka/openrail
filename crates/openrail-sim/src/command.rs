//! Player commands: the only way anything outside the simulation changes
//! the world. In multiplayer, commands are what travels over the network.

use serde::{Deserialize, Serialize};

use crate::world::{NodeId, TrackId, TrainId, Vec2};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct PlayerId(pub u16);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Command {
    BuildNode {
        pos: Vec2,
    },
    BuildTrack {
        a: NodeId,
        b: NodeId,
    },
    /// Turns a node the player owns into a station.
    BuildStation {
        node: NodeId,
    },
    SpawnTrain {
        track: TrackId,
    },
    /// Sends a train around these stations in a loop. An empty list puts
    /// it back into shuttle mode.
    SetRoute {
        train: TrainId,
        stops: Vec<NodeId>,
    },
    RemoveTrain {
        train: TrainId,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandError {
    UnknownNode(NodeId),
    UnknownTrack(TrackId),
    UnknownTrain(TrainId),
    DegenerateTrack,
    NotOwner,
    NotAStation(NodeId),
    TrackOccupied(TrackId),
}

impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CommandError::UnknownNode(id) => write!(f, "node {} does not exist", id.0),
            CommandError::UnknownTrack(id) => write!(f, "track {} does not exist", id.0),
            CommandError::UnknownTrain(id) => write!(f, "train {} does not exist", id.0),
            CommandError::DegenerateTrack => write!(f, "track must join two distinct points"),
            CommandError::NotOwner => write!(f, "that belongs to another player"),
            CommandError::NotAStation(id) => write!(f, "node {} is not a station", id.0),
            CommandError::TrackOccupied(id) => write!(f, "track {} already has a train", id.0),
        }
    }
}

impl std::error::Error for CommandError {}
