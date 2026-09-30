//! Wire messages. Everything is encoded with postcard and sent as
//! length-prefixed frames (see [`crate::codec`]).
//!
//! Only player commands travel over the network. Every peer runs the same
//! deterministic simulation; the host decides the order in which commands
//! are applied and tells everyone in [`TickBundle`]s.

use openrail_sim::{Command, PlayerId};
use serde::{Deserialize, Serialize};

/// Bumped on every incompatible change to these messages or to the
/// simulation's save format. Peers with different versions refuse to play.
pub const PROTOCOL_VERSION: u32 = 2;

/// ALPN protocol id used on the QUIC handshake.
pub const ALPN: &[u8] = b"openrail/1";

/// Longest player name, in characters.
pub const MAX_NAME_CHARS: usize = 32;
/// Longest chat line, in characters.
pub const MAX_CHAT_CHARS: usize = 500;

/// Messages from a client to the host.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClientMsg {
    /// First message on a connection.
    Hello {
        version: u32,
        name: String,
        password: Option<String>,
    },
    /// A command the player wants executed. `client_seq` is chosen by the
    /// client and echoed back in [`ServerMsg::CommandResult`].
    Submit {
        command: Command,
        client_seq: u32,
    },
    /// The client's `World::state_hash` when its world reached `tick`.
    /// Sent every `hash_interval` ticks.
    HashReport {
        tick: u64,
        hash: u64,
    },
    Chat {
        text: String,
    },
}

/// Messages from the host to a client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServerMsg {
    /// Accepted the Hello. `snapshot` is `World::save()` taken when the
    /// host's world was at `tick`; the next bundle the client receives is
    /// the one for `tick`. `terrain_seed` is the seed the world was made
    /// from: the terrain is a function of it (`openrail_sim::terrain`) and
    /// not part of the snapshot.
    Welcome {
        player_id: PlayerId,
        tick: u64,
        snapshot: Vec<u8>,
        terrain_seed: u64,
        hash_interval: u64,
        players: Vec<PlayerInfo>,
    },
    /// Refused the Hello (bad version, password, name, server full). The
    /// connection is closed afterwards.
    Refused {
        reason: String,
    },
    Tick(TickBundle),
    /// Outcome of a submitted command, sent only to its submitter once the
    /// command's tick has been executed on the host.
    CommandResult {
        client_seq: u32,
        tick: u64,
        result: Result<(), String>,
    },
    /// The client's reported hash did not match the host's. A
    /// [`ServerMsg::Resync`] follows.
    Desync {
        tick: u64,
        expected: u64,
        got: u64,
    },
    /// A fresh snapshot replacing the client's world, taken at `tick`.
    Resync {
        tick: u64,
        snapshot: Vec<u8>,
    },
    PlayerJoined(PlayerInfo),
    PlayerLeft {
        player_id: PlayerId,
    },
    Chat {
        from: PlayerId,
        text: String,
    },
    /// The client is being disconnected.
    Kick {
        reason: String,
    },
}

/// Everything that happens in one tick: commands in the order every peer
/// must apply them, before simulating tick `tick`.
///
/// Only commands the host's authoritative world accepted are included, so
/// on every peer in sync each of them applies successfully.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TickBundle {
    pub tick: u64,
    pub commands: Vec<(PlayerId, Command)>,
    /// The host's `state_hash` after simulating up to the given tick
    /// (`World::tick() == .0`). Present every `hash_interval` ticks.
    pub hash_check: Option<(u64, u64)>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayerInfo {
    pub id: PlayerId,
    pub name: String,
    pub connected: bool,
}
