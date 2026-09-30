//! The authoritative side of lockstep, independent of any transport.
//!
//! The host owns the authoritative [`World`]. Commands from clients are
//! queued for tick `now + input_delay`. When the host executes a tick it
//! trial-applies every queued command on its own world, keeps those that
//! succeed, simulates the tick and broadcasts a [`TickBundle`] with exactly
//! the commands it applied. Clients apply bundles in order and therefore
//! reach the same state. Rejected commands never leave the host, so no
//! client ever applies them.
//!
//! The host never waits for clients: a slow client simply falls behind and
//! catches up by simulating several ticks at once.

use std::collections::{BTreeMap, VecDeque};

use openrail_sim::{Command, PlayerId, World, TICKS_PER_SECOND};

use crate::protocol::{
    ClientMsg, PlayerInfo, ServerMsg, TickBundle, MAX_CHAT_CHARS, MAX_NAME_CHARS, PROTOCOL_VERSION,
};

/// Identifies one transport connection. Assigned by the transport.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ConnId(pub u64);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostConfig {
    /// Required in `Hello` when set.
    pub password: Option<String>,
    pub max_players: usize,
    /// Ticks between receiving a command and executing it. 0 means the
    /// next tick the host simulates.
    pub input_delay: u64,
    /// The host and clients compare state hashes every this many ticks.
    pub hash_interval: u64,
    /// Sustained commands (and chat lines) per second per player.
    pub commands_per_second: u32,
    /// How many commands a player may send at once above the sustained
    /// rate.
    pub command_burst: u32,
    /// Rate-limited messages tolerated in a row before the player is
    /// kicked.
    pub kick_after_rate_limited: u32,
    /// Seed the world was created from; clients compute the terrain from
    /// it (see `openrail_sim::terrain`).
    pub terrain_seed: u64,
}

impl Default for HostConfig {
    fn default() -> Self {
        HostConfig {
            password: None,
            max_players: 16,
            input_delay: 0,
            hash_interval: 50,
            commands_per_second: 20,
            command_burst: 40,
            kick_after_rate_limited: 200,
            terrain_seed: 0,
        }
    }
}

/// Something the transport must do on the host's behalf.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostOutput {
    Send {
        to: Vec<ConnId>,
        msg: ServerMsg,
    },
    /// Close the connection after flushing what was sent to it.
    Disconnect(ConnId),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlayerStatus {
    pub id: PlayerId,
    pub name: String,
    pub connected: bool,
    pub desyncs: u32,
}

#[derive(Clone, Debug)]
struct PlayerRecord {
    name: String,
    conn: Option<ConnId>,
    desyncs: u32,
}

#[derive(Clone, Debug)]
struct Joined {
    player: PlayerId,
    /// Token bucket in units of 1/TICKS_PER_SECOND command.
    tokens: u64,
    rate_limited_in_row: u32,
}

#[derive(Clone, Debug)]
struct Queued {
    player: PlayerId,
    conn: ConnId,
    seq: u32,
    command: Command,
}

/// How many recent hashes the host remembers to check late reports.
const HASH_HISTORY: usize = 64;

pub struct LockstepHost {
    world: World,
    cfg: HostConfig,
    conns: BTreeMap<ConnId, Option<Joined>>,
    players: BTreeMap<PlayerId, PlayerRecord>,
    schedule: BTreeMap<u64, Vec<Queued>>,
    hashes: VecDeque<(u64, u64)>,
    out: Vec<HostOutput>,
}

impl LockstepHost {
    pub fn new(world: World, cfg: HostConfig) -> Self {
        let mut cfg = cfg;
        cfg.hash_interval = cfg.hash_interval.max(1);
        LockstepHost {
            world,
            cfg,
            conns: BTreeMap::new(),
            players: BTreeMap::new(),
            schedule: BTreeMap::new(),
            hashes: VecDeque::new(),
            out: Vec::new(),
        }
    }

    pub fn world(&self) -> &World {
        &self.world
    }

    pub fn config(&self) -> &HostConfig {
        &self.cfg
    }

    /// Restores known players (name to id) so that returning players get
    /// their old id and keep owning what they built. Call before anyone
    /// connects.
    pub fn restore_roster(&mut self, roster: impl IntoIterator<Item = (PlayerId, String)>) {
        for (id, name) in roster {
            self.players.insert(
                id,
                PlayerRecord {
                    name,
                    conn: None,
                    desyncs: 0,
                },
            );
        }
    }

    /// Every player that has ever joined, for saving next to the world.
    pub fn roster(&self) -> Vec<(PlayerId, String)> {
        self.players
            .iter()
            .map(|(id, p)| (*id, p.name.clone()))
            .collect()
    }

    pub fn players(&self) -> Vec<PlayerStatus> {
        self.players
            .iter()
            .map(|(id, p)| PlayerStatus {
                id: *id,
                name: p.name.clone(),
                connected: p.conn.is_some(),
                desyncs: p.desyncs,
            })
            .collect()
    }

    /// Takes what the transport must send or do since the last call.
    pub fn drain_output(&mut self) -> Vec<HostOutput> {
        std::mem::take(&mut self.out)
    }

    fn joined_conns(&self) -> Vec<ConnId> {
        self.conns
            .iter()
            .filter(|(_, j)| j.is_some())
            .map(|(c, _)| *c)
            .collect()
    }

    fn send(&mut self, to: ConnId, msg: ServerMsg) {
        self.out.push(HostOutput::Send { to: vec![to], msg });
    }

    fn broadcast(&mut self, msg: ServerMsg) {
        let to = self.joined_conns();
        if !to.is_empty() {
            self.out.push(HostOutput::Send { to, msg });
        }
    }

    fn player_info(&self, id: PlayerId) -> PlayerInfo {
        let p = &self.players[&id];
        PlayerInfo {
            id,
            name: p.name.clone(),
            connected: p.conn.is_some(),
        }
    }

    fn refuse(&mut self, conn: ConnId, reason: &str) {
        self.send(
            conn,
            ServerMsg::Refused {
                reason: reason.into(),
            },
        );
        self.out.push(HostOutput::Disconnect(conn));
        self.conns.remove(&conn);
    }

    /// Kicks a connection, joined or not.
    pub fn kick(&mut self, conn: ConnId, reason: &str) {
        self.send(
            conn,
            ServerMsg::Kick {
                reason: reason.into(),
            },
        );
        self.out.push(HostOutput::Disconnect(conn));
        self.disconnected(conn);
    }

    /// The transport noticed that a connection is gone.
    pub fn disconnected(&mut self, conn: ConnId) {
        let Some(Some(j)) = self.conns.remove(&conn) else {
            return;
        };
        if let Some(p) = self.players.get_mut(&j.player) {
            p.conn = None;
        }
        self.broadcast(ServerMsg::PlayerLeft {
            player_id: j.player,
        });
    }

    /// Handles one message from a connection.
    pub fn handle(&mut self, conn: ConnId, msg: ClientMsg) {
        let state = self.conns.entry(conn).or_insert(None).clone();
        match (state, msg) {
            (
                None,
                ClientMsg::Hello {
                    version,
                    name,
                    password,
                },
            ) => self.hello(conn, version, name, password),
            (None, _) => self.refuse(conn, "expected Hello"),
            (Some(_), ClientMsg::Hello { .. }) => self.kick(conn, "duplicate Hello"),
            (
                Some(j),
                ClientMsg::Submit {
                    command,
                    client_seq,
                },
            ) => {
                if self.take_token(conn) {
                    let tick = self.world.tick() + self.cfg.input_delay;
                    self.schedule.entry(tick).or_default().push(Queued {
                        player: j.player,
                        conn,
                        seq: client_seq,
                        command,
                    });
                } else if self.conns.contains_key(&conn) {
                    self.send(
                        conn,
                        ServerMsg::CommandResult {
                            client_seq,
                            tick: self.world.tick(),
                            result: Err("rate limited".into()),
                        },
                    );
                }
            }
            (Some(j), ClientMsg::HashReport { tick, hash }) => {
                self.check_report(conn, j.player, tick, hash)
            }
            (Some(j), ClientMsg::Chat { text }) => {
                if self.take_token(conn) {
                    let text: String = text
                        .chars()
                        .filter(|c| !c.is_control())
                        .take(MAX_CHAT_CHARS)
                        .collect();
                    if !text.trim().is_empty() {
                        self.broadcast(ServerMsg::Chat {
                            from: j.player,
                            text,
                        });
                    }
                }
            }
        }
    }

    fn hello(&mut self, conn: ConnId, version: u32, name: String, password: Option<String>) {
        if version != PROTOCOL_VERSION {
            let reason = format!(
                "protocol version {version} not supported, server speaks {PROTOCOL_VERSION}"
            );
            return self.refuse(conn, &reason);
        }
        if let Some(expected) = &self.cfg.password {
            let ok = password
                .as_deref()
                .is_some_and(|p| constant_time_eq(p.as_bytes(), expected.as_bytes()));
            if !ok {
                return self.refuse(conn, "wrong password");
            }
        }
        let name = name.trim().to_string();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return self.refuse(conn, "invalid name");
        }
        let existing = self
            .players
            .iter()
            .find(|(_, p)| p.name == name)
            .map(|(id, p)| (*id, p.conn.is_some()));
        let connected = self.players.values().filter(|p| p.conn.is_some()).count();
        let player = match existing {
            Some((_, true)) => return self.refuse(conn, "name already in use"),
            _ if connected >= self.cfg.max_players => return self.refuse(conn, "server full"),
            Some((id, false)) => id,
            // PlayerId(0) is the single-player / neutral id, so start at 1.
            None => match self.players.keys().next_back() {
                None => PlayerId(1),
                Some(last) => match last.0.checked_add(1) {
                    Some(n) => PlayerId(n),
                    None => return self.refuse(conn, "no player ids left"),
                },
            },
        };
        self.players.insert(
            player,
            PlayerRecord {
                name,
                conn: Some(conn),
                desyncs: self.players.get(&player).map_or(0, |p| p.desyncs),
            },
        );
        let info = self.player_info(player);
        // Tell the others before this connection counts as joined.
        self.broadcast(ServerMsg::PlayerJoined(info));
        self.conns.insert(
            conn,
            Some(Joined {
                player,
                tokens: self.bucket_capacity(),
                rate_limited_in_row: 0,
            }),
        );
        let players = self
            .players
            .keys()
            .map(|id| self.player_info(*id))
            .collect();
        self.send(
            conn,
            ServerMsg::Welcome {
                player_id: player,
                tick: self.world.tick(),
                snapshot: self.world.save(),
                terrain_seed: self.cfg.terrain_seed,
                hash_interval: self.cfg.hash_interval,
                players,
            },
        );
    }

    fn bucket_capacity(&self) -> u64 {
        u64::from(self.cfg.command_burst.max(1)) * u64::from(TICKS_PER_SECOND)
    }

    /// Spends one token of the connection's rate limit. Kicks it when it
    /// keeps flooding.
    fn take_token(&mut self, conn: ConnId) -> bool {
        let cost = u64::from(TICKS_PER_SECOND);
        let kick_after = self.cfg.kick_after_rate_limited;
        let Some(Some(j)) = self.conns.get_mut(&conn) else {
            return false;
        };
        if j.tokens >= cost {
            j.tokens -= cost;
            j.rate_limited_in_row = 0;
            true
        } else {
            j.rate_limited_in_row += 1;
            if j.rate_limited_in_row > kick_after {
                self.kick(conn, "flooding");
            }
            false
        }
    }

    fn check_report(&mut self, conn: ConnId, player: PlayerId, tick: u64, hash: u64) {
        let Some(&(_, expected)) = self.hashes.iter().find(|(t, _)| *t == tick) else {
            // Too old to check, or from the future (which a well-behaved
            // client cannot send). Either way there is nothing to compare.
            return;
        };
        if expected == hash {
            return;
        }
        if let Some(p) = self.players.get_mut(&player) {
            p.desyncs += 1;
        }
        self.send(
            conn,
            ServerMsg::Desync {
                tick,
                expected,
                got: hash,
            },
        );
        self.send(
            conn,
            ServerMsg::Resync {
                tick: self.world.tick(),
                snapshot: self.world.save(),
            },
        );
    }

    /// Executes one tick: applies the commands due now, simulates, and
    /// broadcasts the bundle.
    pub fn tick(&mut self) {
        let now = self.world.tick();
        let queued = self.schedule.remove(&now).unwrap_or_default();
        let mut commands = Vec::with_capacity(queued.len());
        for q in queued {
            let result = self.world.apply(q.player, &q.command);
            if self.conns.contains_key(&q.conn) {
                self.send(
                    q.conn,
                    ServerMsg::CommandResult {
                        client_seq: q.seq,
                        tick: now,
                        result: result.as_ref().map(|_| ()).map_err(|e| e.to_string()),
                    },
                );
            }
            if result.is_ok() {
                commands.push((q.player, q.command));
            }
        }
        self.world.step();
        let after = self.world.tick();
        let hash_check = (after % self.cfg.hash_interval == 0).then(|| {
            let h = self.world.state_hash();
            self.hashes.push_back((after, h));
            if self.hashes.len() > HASH_HISTORY {
                self.hashes.pop_front();
            }
            (after, h)
        });
        self.broadcast(ServerMsg::Tick(TickBundle {
            tick: now,
            commands,
            hash_check,
        }));

        // Refill rate-limit buckets.
        let cap = self.bucket_capacity();
        let refill = u64::from(self.cfg.commands_per_second);
        for j in self.conns.values_mut().flatten() {
            j.tokens = (j.tokens + refill).min(cap);
        }
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use openrail_sim::{Fixed, Vec2};

    fn hello(name: &str) -> ClientMsg {
        ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            name: name.into(),
            password: None,
        }
    }

    fn node(x: i32) -> Command {
        Command::BuildNode {
            pos: Vec2::new(Fixed::from_int(x), Fixed::ZERO),
        }
    }

    fn msgs_to(out: &[HostOutput], conn: ConnId) -> Vec<ServerMsg> {
        out.iter()
            .filter_map(|o| match o {
                HostOutput::Send { to, msg } if to.contains(&conn) => Some(msg.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn assigns_ids_and_reuses_them_on_rejoin() {
        let mut h = LockstepHost::new(World::new(1), HostConfig::default());
        h.handle(ConnId(1), hello("ann"));
        h.handle(ConnId(2), hello("bob"));
        h.handle(ConnId(3), hello("ann"));
        let out = h.drain_output();
        assert!(matches!(
            msgs_to(&out, ConnId(1))[0],
            ServerMsg::Welcome {
                player_id: PlayerId(1),
                ..
            }
        ));
        assert!(matches!(
            msgs_to(&out, ConnId(2))[0],
            ServerMsg::Welcome {
                player_id: PlayerId(2),
                ..
            }
        ));
        assert!(matches!(
            msgs_to(&out, ConnId(3))[0],
            ServerMsg::Refused { .. }
        ));
        assert!(out.contains(&HostOutput::Disconnect(ConnId(3))));

        h.disconnected(ConnId(1));
        h.handle(ConnId(4), hello("ann"));
        let out = h.drain_output();
        assert!(matches!(
            msgs_to(&out, ConnId(4))[0],
            ServerMsg::Welcome {
                player_id: PlayerId(1),
                ..
            }
        ));
    }

    #[test]
    fn password_and_version_are_checked() {
        let cfg = HostConfig {
            password: Some("secret".into()),
            ..HostConfig::default()
        };
        let mut h = LockstepHost::new(World::new(1), cfg);
        h.handle(ConnId(1), hello("ann"));
        h.handle(
            ConnId(2),
            ClientMsg::Hello {
                version: PROTOCOL_VERSION + 1,
                name: "bob".into(),
                password: Some("secret".into()),
            },
        );
        h.handle(
            ConnId(3),
            ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                name: "cid".into(),
                password: Some("secret".into()),
            },
        );
        let out = h.drain_output();
        assert!(matches!(
            msgs_to(&out, ConnId(1))[0],
            ServerMsg::Refused { .. }
        ));
        assert!(matches!(
            msgs_to(&out, ConnId(2))[0],
            ServerMsg::Refused { .. }
        ));
        assert!(matches!(
            msgs_to(&out, ConnId(3))[0],
            ServerMsg::Welcome { .. }
        ));
    }

    #[test]
    fn rejected_commands_are_not_broadcast() {
        let mut h = LockstepHost::new(World::new(1), HostConfig::default());
        h.handle(ConnId(1), hello("ann"));
        h.handle(
            ConnId(1),
            ClientMsg::Submit {
                command: node(5),
                client_seq: 1,
            },
        );
        h.handle(
            ConnId(1),
            ClientMsg::Submit {
                command: Command::BuildStation {
                    node: openrail_sim::NodeId(99),
                },
                client_seq: 2,
            },
        );
        h.drain_output();
        h.tick();
        let out = msgs_to(&h.drain_output(), ConnId(1));
        let bundle = out
            .iter()
            .find_map(|m| match m {
                ServerMsg::Tick(b) => Some(b.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(bundle.tick, 0);
        assert_eq!(bundle.commands, vec![(PlayerId(1), node(5))]);
        assert!(out.contains(&ServerMsg::CommandResult {
            client_seq: 1,
            tick: 0,
            result: Ok(())
        }));
        assert!(out.iter().any(|m| matches!(
            m,
            ServerMsg::CommandResult {
                client_seq: 2,
                result: Err(_),
                ..
            }
        )));
    }

    #[test]
    fn flooding_is_rate_limited_then_kicked() {
        let cfg = HostConfig {
            command_burst: 5,
            kick_after_rate_limited: 10,
            ..HostConfig::default()
        };
        let mut h = LockstepHost::new(World::new(1), cfg);
        h.handle(ConnId(1), hello("ann"));
        h.drain_output();
        for seq in 0..10 {
            h.handle(
                ConnId(1),
                ClientMsg::Submit {
                    command: node(seq),
                    client_seq: seq as u32,
                },
            );
        }
        let out = h.drain_output();
        let limited = msgs_to(&out, ConnId(1))
            .iter()
            .filter(|m| matches!(m, ServerMsg::CommandResult { result: Err(_), .. }))
            .count();
        assert_eq!(limited, 5);
        h.tick();
        let bundle_len = h
            .drain_output()
            .iter()
            .find_map(|o| match o {
                HostOutput::Send {
                    msg: ServerMsg::Tick(b),
                    ..
                } => Some(b.commands.len()),
                _ => None,
            })
            .unwrap();
        assert_eq!(bundle_len, 5);

        for seq in 0..20 {
            h.handle(
                ConnId(1),
                ClientMsg::Submit {
                    command: node(seq),
                    client_seq: seq as u32,
                },
            );
        }
        let out = h.drain_output();
        assert!(out.contains(&HostOutput::Disconnect(ConnId(1))));
        assert!(!h.players()[0].connected);
    }

    #[test]
    fn wrong_hash_report_triggers_resync() {
        let cfg = HostConfig {
            hash_interval: 5,
            ..HostConfig::default()
        };
        let mut h = LockstepHost::new(World::new(1), cfg);
        h.handle(ConnId(1), hello("ann"));
        for _ in 0..5 {
            h.tick();
        }
        h.drain_output();
        let good = h.world().state_hash();
        h.handle(
            ConnId(1),
            ClientMsg::HashReport {
                tick: 5,
                hash: good,
            },
        );
        assert!(h.drain_output().is_empty());
        h.handle(
            ConnId(1),
            ClientMsg::HashReport {
                tick: 5,
                hash: good ^ 1,
            },
        );
        let out = msgs_to(&h.drain_output(), ConnId(1));
        assert!(matches!(out[0], ServerMsg::Desync { tick: 5, .. }));
        assert!(matches!(out[1], ServerMsg::Resync { tick: 5, .. }));
        assert_eq!(h.players()[0].desyncs, 1);
    }
}
