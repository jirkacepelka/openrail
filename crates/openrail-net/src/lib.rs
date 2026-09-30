//! Online multiplayer for OpenRail: deterministic lockstep.
//!
//! Only player commands travel over the network. The host (the dedicated
//! server) decides in which tick and in which order commands run, applies
//! them to its own authoritative world, and broadcasts one
//! [`protocol::TickBundle`] per tick. Every client applies the same bundles
//! to its copy of the world and so reaches the same state; state hashes are
//! compared every few ticks to catch a desync.
//!
//! - [`protocol`]: the wire messages.
//! - [`codec`]: length-prefixed postcard framing.
//! - [`host`] and [`client`]: transport-agnostic state machines, testable
//!   without sockets.
//! - `quic` (feature `quic`, on by default): the QUIC transport.

pub mod client;
pub mod codec;
pub mod host;
pub mod protocol;
#[cfg(feature = "quic")]
pub mod quic;

pub use client::{ClientEvent, ClientState, LockstepClient};
pub use host::{ConnId, HostConfig, HostOutput, LockstepHost, PlayerStatus};
pub use protocol::{ClientMsg, PlayerInfo, ServerMsg, TickBundle, PROTOCOL_VERSION};
