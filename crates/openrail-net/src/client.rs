//! The client side of lockstep, independent of any transport.
//!
//! Feed every [`ServerMsg`] to [`LockstepClient::handle`], call
//! [`LockstepClient::advance`] once per frame to simulate the ticks the host
//! has confirmed, and send what [`LockstepClient::drain_outgoing`] returns.
//! The local world only ever changes through confirmed bundles, so a
//! client's own commands take one round trip to show up.

use std::collections::VecDeque;

use openrail_sim::{Command, PlayerId, World};

use crate::protocol::{ClientMsg, PlayerInfo, ServerMsg, TickBundle, PROTOCOL_VERSION};

/// Things the game UI may want to react to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientEvent {
    Joined {
        player_id: PlayerId,
        tick: u64,
    },
    Refused {
        reason: String,
    },
    Kicked {
        reason: String,
    },
    CommandResult {
        client_seq: u32,
        tick: u64,
        result: Result<(), String>,
    },
    PlayerJoined(PlayerInfo),
    PlayerLeft {
        player_id: PlayerId,
    },
    Chat {
        from: PlayerId,
        text: String,
    },
    /// The local world diverged from the host's. Detected either locally
    /// (bundle hash check, a confirmed command failing to apply) or by the
    /// host; a resync snapshot from the host fixes it.
    Desync {
        tick: u64,
    },
    Resynced {
        tick: u64,
    },
    /// The host sent something that does not fit the protocol.
    ProtocolError(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientState {
    /// Waiting for Welcome.
    Connecting,
    Playing,
    /// Refused or kicked; nothing more will happen.
    Closed,
}

pub struct LockstepClient {
    state: ClientState,
    player_id: Option<PlayerId>,
    world: Option<World>,
    hash_interval: u64,
    bundles: VecDeque<TickBundle>,
    players: Vec<PlayerInfo>,
    next_seq: u32,
    outgoing: Vec<ClientMsg>,
    events: Vec<ClientEvent>,
    desynced: bool,
    desyncs: u32,
}

impl LockstepClient {
    /// A new client; its first outgoing message is the Hello.
    pub fn new(name: impl Into<String>, password: Option<String>) -> Self {
        LockstepClient {
            state: ClientState::Connecting,
            player_id: None,
            world: None,
            hash_interval: 0,
            bundles: VecDeque::new(),
            players: Vec::new(),
            next_seq: 0,
            outgoing: vec![ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                name: name.into(),
                password,
            }],
            events: Vec::new(),
            desynced: false,
            desyncs: 0,
        }
    }

    pub fn state(&self) -> ClientState {
        self.state
    }

    pub fn player_id(&self) -> Option<PlayerId> {
        self.player_id
    }

    /// The local copy of the world, once joined.
    pub fn world(&self) -> Option<&World> {
        self.world.as_ref()
    }

    pub fn players(&self) -> &[PlayerInfo] {
        &self.players
    }

    /// Confirmed ticks received but not simulated yet.
    pub fn backlog(&self) -> usize {
        self.bundles.len()
    }

    /// How many times this client has been out of sync.
    pub fn desyncs(&self) -> u32 {
        self.desyncs
    }

    /// Queues a command for the host. Returns the sequence number that
    /// the matching [`ClientEvent::CommandResult`] will carry.
    pub fn submit(&mut self, command: Command) -> u32 {
        let client_seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        self.outgoing.push(ClientMsg::Submit {
            command,
            client_seq,
        });
        client_seq
    }

    pub fn chat(&mut self, text: impl Into<String>) {
        self.outgoing.push(ClientMsg::Chat { text: text.into() });
    }

    /// Messages to send to the host, in order. Before Welcome only the
    /// Hello is released; submissions wait.
    pub fn drain_outgoing(&mut self) -> Vec<ClientMsg> {
        match self.state {
            ClientState::Closed => {
                self.outgoing.clear();
                Vec::new()
            }
            ClientState::Connecting => {
                let n = self
                    .outgoing
                    .iter()
                    .take_while(|m| matches!(m, ClientMsg::Hello { .. }))
                    .count();
                self.outgoing.drain(..n).collect()
            }
            ClientState::Playing => std::mem::take(&mut self.outgoing),
        }
    }

    pub fn drain_events(&mut self) -> Vec<ClientEvent> {
        std::mem::take(&mut self.events)
    }

    fn load(&mut self, tick: u64, snapshot: &[u8]) -> bool {
        match World::load(snapshot) {
            Ok(w) if w.tick() == tick => {
                self.world = Some(w);
                self.bundles.retain(|b| b.tick >= tick);
                self.desynced = false;
                true
            }
            Ok(w) => {
                self.events.push(ClientEvent::ProtocolError(format!(
                    "snapshot is at tick {} but claims {tick}",
                    w.tick()
                )));
                false
            }
            Err(e) => {
                self.events
                    .push(ClientEvent::ProtocolError(format!("bad snapshot: {e}")));
                false
            }
        }
    }

    pub fn handle(&mut self, msg: ServerMsg) {
        if self.state == ClientState::Closed {
            return;
        }
        match msg {
            ServerMsg::Welcome {
                player_id,
                tick,
                snapshot,
                hash_interval,
                players,
            } => {
                if self.state != ClientState::Connecting {
                    self.events
                        .push(ClientEvent::ProtocolError("unexpected Welcome".into()));
                    return;
                }
                if self.load(tick, &snapshot) {
                    self.state = ClientState::Playing;
                    self.player_id = Some(player_id);
                    self.hash_interval = hash_interval.max(1);
                    self.players = players;
                    self.events.push(ClientEvent::Joined { player_id, tick });
                }
            }
            ServerMsg::Refused { reason } => {
                self.state = ClientState::Closed;
                self.events.push(ClientEvent::Refused { reason });
            }
            ServerMsg::Kick { reason } => {
                self.state = ClientState::Closed;
                self.events.push(ClientEvent::Kicked { reason });
            }
            ServerMsg::Tick(bundle) => {
                let expected = self
                    .bundles
                    .back()
                    .map(|b| b.tick + 1)
                    .or(self.world.as_ref().map(World::tick));
                if expected != Some(bundle.tick) {
                    self.events.push(ClientEvent::ProtocolError(format!(
                        "bundle for tick {} out of order (expected {expected:?})",
                        bundle.tick
                    )));
                    return;
                }
                self.bundles.push_back(bundle);
            }
            ServerMsg::CommandResult {
                client_seq,
                tick,
                result,
            } => self.events.push(ClientEvent::CommandResult {
                client_seq,
                tick,
                result,
            }),
            ServerMsg::Desync { tick, .. } => self.flag_desync(tick),
            ServerMsg::Resync { tick, snapshot } => {
                if self.load(tick, &snapshot) {
                    self.events.push(ClientEvent::Resynced { tick });
                }
            }
            ServerMsg::PlayerJoined(info) => {
                match self.players.iter_mut().find(|p| p.id == info.id) {
                    Some(p) => *p = info.clone(),
                    None => self.players.push(info.clone()),
                }
                self.events.push(ClientEvent::PlayerJoined(info));
            }
            ServerMsg::PlayerLeft { player_id } => {
                if let Some(p) = self.players.iter_mut().find(|p| p.id == player_id) {
                    p.connected = false;
                }
                self.events.push(ClientEvent::PlayerLeft { player_id });
            }
            ServerMsg::Chat { from, text } => self.events.push(ClientEvent::Chat { from, text }),
        }
    }

    fn flag_desync(&mut self, tick: u64) {
        if !self.desynced {
            self.desynced = true;
            self.desyncs += 1;
            self.events.push(ClientEvent::Desync { tick });
        }
    }

    /// Simulates up to `max_ticks` confirmed ticks. Returns how many ran.
    /// Pass a small number to spread catching up over several frames.
    pub fn advance(&mut self, max_ticks: usize) -> usize {
        let mut ran = 0;
        while ran < max_ticks {
            let Some(world) = self.world.as_mut() else {
                break;
            };
            let Some(bundle) = self.bundles.pop_front() else {
                break;
            };
            let mut failed = false;
            for (player, cmd) in &bundle.commands {
                // The host only sends commands that applied on its world,
                // so a failure here means we are out of sync.
                failed |= world.apply(*player, cmd).is_err();
            }
            world.step();
            ran += 1;
            let now = world.tick();
            let mut mismatch = failed;
            let check = bundle.hash_check.filter(|(t, _)| *t == now);
            let report = now % self.hash_interval == 0;
            if check.is_some() || report {
                let hash = world.state_hash();
                mismatch |= check.is_some_and(|(_, h)| h != hash);
                if report {
                    self.outgoing
                        .push(ClientMsg::HashReport { tick: now, hash });
                }
            }
            if mismatch {
                self.flag_desync(now);
            }
        }
        ran
    }
}
