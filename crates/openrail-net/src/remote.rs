//! A lockstep client for game frontends that must never block.
//!
//! [`RemoteClient`] runs the QUIC side (name lookup, handshake, stream
//! reader and writer) on a background thread with its own tokio runtime.
//! Everything else lives on the thread that owns the `RemoteClient`
//! (Godot's main thread): the [`LockstepClient`] state machine, the local
//! copy of the world and the simulation of confirmed ticks. The two sides
//! only talk through channels, so [`RemoteClient::poll`] never waits.
//!
//! On top of the plain lockstep client it tracks the commands this player
//! submitted and reports each one as [`RemoteEvent::CommandDone`] once its
//! outcome is visible in the local world: a rejection as soon as the host
//! reports it, a success only after the tick that applied it has been
//! simulated locally, together with the id of the node, track or train the
//! command created. Frontends can therefore chain commands (build two
//! nodes, then a track between them) without guessing ids.

use std::{
    collections::{BTreeMap, BTreeSet},
    net::SocketAddr,
    sync::mpsc as std_mpsc,
    time::{Duration, Instant},
};

use openrail_sim::{Command, PlayerId, World};
use tokio::sync::{mpsc, oneshot};

use crate::{
    client::{ClientEvent, ClientState, LockstepClient},
    codec::encode,
    protocol::{PlayerInfo, ServerMsg},
    quic::{ClientLink, NetError, ServerVerification},
};

/// How long name lookup plus the QUIC handshake may take.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long to wait for the Welcome (the world snapshot) once connected.
pub const JOIN_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteState {
    /// Resolving the address and doing the QUIC handshake.
    Connecting,
    /// Connected, Hello sent, waiting for the Welcome.
    Joining,
    /// Joined; the world advances as confirmed ticks arrive.
    Playing,
    /// Failed, refused, kicked, disconnected or left. Final.
    Closed,
}

impl RemoteState {
    pub fn as_str(self) -> &'static str {
        match self {
            RemoteState::Connecting => "connecting",
            RemoteState::Joining => "joining",
            RemoteState::Playing => "playing",
            RemoteState::Closed => "closed",
        }
    }
}

/// What [`RemoteClient::poll`] reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteEvent {
    /// The QUIC connection is up and the Hello was sent.
    Connected,
    /// The host accepted us; the world is available from now on.
    Joined {
        player_id: PlayerId,
        tick: u64,
    },
    /// Could not join: unreachable, bad certificate, refused, timed out.
    Failed {
        reason: String,
    },
    /// Lost the game after joining: kicked or the connection dropped.
    Disconnected {
        reason: String,
    },
    /// Outcome of a command from [`RemoteClient::submit`]. `Ok(Some(id))`
    /// is the id of the node, track or train it created; `Ok(None)` for
    /// commands that create nothing (or, after a resync, when the id could
    /// not be determined). Successes are reported only once the local
    /// world contains the change.
    CommandDone {
        seq: u32,
        result: Result<Option<u32>, String>,
    },
    PlayerJoined(PlayerInfo),
    PlayerLeft {
        player_id: PlayerId,
    },
    Chat {
        from: PlayerId,
        text: String,
    },
    /// The local world diverged from the host's; a resync follows.
    Desync {
        tick: u64,
    },
    /// The world was replaced by a fresh snapshot from the host.
    Resynced {
        tick: u64,
    },
    /// Nodes, tracks, stations, trains or routes changed since the last
    /// poll (at most one per poll). Train movement alone does not count.
    WorldChanged,
}

/// What kind of entity a command creates, to report its id.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Creates {
    Node,
    Track,
    Train,
    Nothing,
}

impl Creates {
    fn of(cmd: &Command) -> Self {
        match cmd {
            Command::BuildNode { .. } => Creates::Node,
            Command::BuildTrack { .. } => Creates::Track,
            Command::SpawnTrain { .. } => Creates::Train,
            _ => Creates::Nothing,
        }
    }
}

/// Highest node, track and train ids in a world. World ids come from one
/// increasing counter, so anything created later has a higher id than all
/// of these.
#[derive(Clone, Copy)]
struct MaxIds {
    node: u32,
    track: u32,
    train: u32,
}

impl MaxIds {
    fn of(world: &World) -> Self {
        MaxIds {
            node: world.nodes().map(|(id, _)| id.0).max().unwrap_or(0),
            track: world.tracks().map(|(id, _)| id.0).max().unwrap_or(0),
            train: world.trains().map(|(id, _)| id.0).max().unwrap_or(0),
        }
    }
}

/// The main-thread end of the network thread.
struct Link {
    conn: quinn::Connection,
    inbox: mpsc::UnboundedReceiver<ServerMsg>,
    outbox: mpsc::UnboundedSender<Vec<u8>>,
}

/// Parses a certificate fingerprint as typed by a player: 64 hex digits,
/// optionally with `:` separators. Empty means no pinning (development
/// only, see [`ServerVerification::InsecureAcceptAny`]).
pub fn verification_from_str(fingerprint: &str) -> Result<ServerVerification, NetError> {
    let f = fingerprint.trim();
    if f.is_empty() {
        Ok(ServerVerification::InsecureAcceptAny)
    } else {
        Ok(ServerVerification::Pinned(f.parse()?))
    }
}

pub struct RemoteClient {
    client: LockstepClient,
    state: RemoteState,
    status: String,
    name: String,
    ready: Option<std_mpsc::Receiver<Result<Link, String>>>,
    link: Option<Link>,
    /// Dropping or firing it tells the network thread to close.
    shutdown: Option<oneshot::Sender<()>>,
    joining_since: Option<Instant>,
    /// Submitted commands without a result yet.
    pending: BTreeMap<u32, Creates>,
    /// Accepted commands by the tick that applies them, in apply order,
    /// waiting for that tick to be simulated locally.
    confirmed: BTreeMap<u64, Vec<(u32, Creates)>>,
    /// Ticks received whose bundle has commands.
    structural: BTreeSet<u64>,
    world_changed: bool,
    events: Vec<RemoteEvent>,
}

impl RemoteClient {
    /// Starts connecting in the background and returns at once. `address`
    /// is a host name or IP address (IPv6 with or without brackets).
    /// Progress and the outcome arrive through [`RemoteClient::poll`].
    pub fn connect(
        address: &str,
        port: u16,
        verification: ServerVerification,
        name: &str,
        password: Option<String>,
    ) -> Result<RemoteClient, NetError> {
        let host = address
            .trim()
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_string();
        if host.is_empty() {
            return Err(NetError("no server address given".into()));
        }
        let (ready_tx, ready_rx) = std_mpsc::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let status = format!("Connecting to {host} port {port}...");
        std::thread::Builder::new()
            .name("openrail-net".into())
            .spawn(move || network_thread(host, port, verification, ready_tx, shutdown_rx))
            .map_err(|e| NetError(format!("starting network thread: {e}")))?;
        Ok(RemoteClient {
            client: LockstepClient::new(name, password.filter(|p| !p.is_empty())),
            state: RemoteState::Connecting,
            status,
            name: name.trim().to_string(),
            ready: Some(ready_rx),
            link: None,
            shutdown: Some(shutdown_tx),
            joining_since: None,
            pending: BTreeMap::new(),
            confirmed: BTreeMap::new(),
            structural: BTreeSet::new(),
            world_changed: false,
            events: Vec::new(),
        })
    }

    pub fn state(&self) -> RemoteState {
        self.state
    }

    /// One line for the UI describing the connection.
    pub fn status(&self) -> &str {
        &self.status
    }

    pub fn player_id(&self) -> Option<PlayerId> {
        self.client.player_id()
    }

    /// Seed of the host's world, for the terrain (0 before joining).
    pub fn terrain_seed(&self) -> u64 {
        self.client.terrain_seed()
    }

    /// The confirmed world, once joined. It stays readable after the
    /// connection closes.
    pub fn world(&self) -> Option<&World> {
        self.client.world()
    }

    pub fn players(&self) -> &[PlayerInfo] {
        self.client.players()
    }

    /// Confirmed ticks received but not simulated yet.
    pub fn backlog(&self) -> usize {
        self.client.backlog()
    }

    /// Queues a command for the host. Returns the sequence number its
    /// [`RemoteEvent::CommandDone`] will carry, or `None` once closed.
    pub fn submit(&mut self, command: Command) -> Option<u32> {
        if self.state == RemoteState::Closed {
            return None;
        }
        let kind = Creates::of(&command);
        let seq = self.client.submit(command);
        self.pending.insert(seq, kind);
        self.flush();
        Some(seq)
    }

    pub fn chat(&mut self, text: &str) {
        if self.state != RemoteState::Closed {
            self.client.chat(text);
            self.flush();
        }
    }

    /// Leaves the game and closes the connection. Pending commands are not
    /// reported any more.
    pub fn leave(&mut self) {
        if self.state == RemoteState::Closed {
            return;
        }
        self.pending.clear();
        self.confirmed.clear();
        self.shut_down(RemoteState::Closed, "Left the server".into());
    }

    /// Never blocks: takes what the network thread received, simulates up
    /// to `max_ticks` confirmed ticks, sends what is due, and returns what
    /// happened since the last call.
    pub fn poll(&mut self, max_ticks: usize) -> Vec<RemoteEvent> {
        if self.state == RemoteState::Connecting {
            self.poll_ready();
        }
        if self.link.is_some() {
            let lost = self.receive();
            self.translate();
            if self.state == RemoteState::Playing {
                self.advance(max_ticks);
                self.translate();
            }
            self.flush();
            if lost && self.state != RemoteState::Closed {
                self.connection_lost();
            }
        }
        if self.state == RemoteState::Joining
            && self
                .joining_since
                .is_some_and(|t| t.elapsed() > JOIN_TIMEOUT)
        {
            self.fail("the server did not let us join in time".into());
        }
        if std::mem::take(&mut self.world_changed) {
            self.events.push(RemoteEvent::WorldChanged);
        }
        std::mem::take(&mut self.events)
    }

    fn poll_ready(&mut self) {
        let Some(ready) = &self.ready else {
            return;
        };
        match ready.try_recv() {
            Ok(Ok(link)) => {
                self.ready = None;
                self.link = Some(link);
                self.state = RemoteState::Joining;
                self.joining_since = Some(Instant::now());
                self.status = format!("Connected, joining as {}...", self.name);
                self.events.push(RemoteEvent::Connected);
                self.flush(); // the Hello
            }
            Ok(Err(reason)) => self.fail(reason),
            Err(std_mpsc::TryRecvError::Empty) => {}
            Err(std_mpsc::TryRecvError::Disconnected) => {
                self.fail("the network thread stopped".into())
            }
        }
    }

    /// Hands every received message to the state machine. Returns `true`
    /// when the connection is gone.
    fn receive(&mut self) -> bool {
        let Some(link) = self.link.as_mut() else {
            return false;
        };
        loop {
            match link.inbox.try_recv() {
                Ok(msg) => {
                    if let ServerMsg::Tick(b) = &msg {
                        if !b.commands.is_empty() {
                            self.structural.insert(b.tick);
                        }
                    }
                    self.client.handle(msg);
                    if self.client.state() == ClientState::Closed {
                        // Refused or kicked: ignore anything after that.
                        return false;
                    }
                }
                Err(mpsc::error::TryRecvError::Empty) => return false,
                Err(mpsc::error::TryRecvError::Disconnected) => return true,
            }
        }
    }

    /// Turns lockstep client events into ours.
    fn translate(&mut self) {
        for ev in self.client.drain_events() {
            if self.state == RemoteState::Closed {
                break;
            }
            match ev {
                ClientEvent::Joined { player_id, tick } => {
                    self.state = RemoteState::Playing;
                    self.joining_since = None;
                    self.status = format!("Playing as {} (player {})", self.name, player_id.0);
                    self.world_changed = true;
                    self.events.push(RemoteEvent::Joined { player_id, tick });
                }
                ClientEvent::Refused { reason } => self.fail(format!("refused: {reason}")),
                ClientEvent::Kicked { reason } => {
                    let reason = format!("kicked: {reason}");
                    if self.state == RemoteState::Playing {
                        self.disconnect(reason);
                    } else {
                        self.fail(reason);
                    }
                }
                ClientEvent::CommandResult {
                    client_seq,
                    tick,
                    result,
                } => self.command_result(client_seq, tick, result),
                ClientEvent::PlayerJoined(info) => {
                    self.events.push(RemoteEvent::PlayerJoined(info))
                }
                ClientEvent::PlayerLeft { player_id } => {
                    self.events.push(RemoteEvent::PlayerLeft { player_id })
                }
                ClientEvent::Chat { from, text } => {
                    self.events.push(RemoteEvent::Chat { from, text })
                }
                ClientEvent::Desync { tick } => self.events.push(RemoteEvent::Desync { tick }),
                ClientEvent::Resynced { tick } => {
                    // Bundles before `tick` were dropped, so ids of commands
                    // applied there cannot be worked out any more.
                    let later = self.confirmed.split_off(&tick);
                    for (seq, _) in std::mem::replace(&mut self.confirmed, later)
                        .into_values()
                        .flatten()
                    {
                        self.events.push(RemoteEvent::CommandDone {
                            seq,
                            result: Ok(None),
                        });
                    }
                    self.structural = self.structural.split_off(&tick);
                    self.world_changed = true;
                    self.events.push(RemoteEvent::Resynced { tick });
                }
                ClientEvent::ProtocolError(e) => {
                    // The stream cannot recover from this; better to say so
                    // than to stall silently.
                    let reason = format!("protocol error: {e}");
                    if self.state == RemoteState::Playing {
                        self.disconnect(reason);
                    } else {
                        self.fail(reason);
                    }
                }
            }
        }
    }

    fn command_result(&mut self, seq: u32, tick: u64, result: Result<(), String>) {
        let Some(kind) = self.pending.remove(&seq) else {
            return;
        };
        match result {
            Err(e) => self.events.push(RemoteEvent::CommandDone {
                seq,
                result: Err(e),
            }),
            // The host sends a result before the bundle of its tick, so the
            // tick is normally still ahead of the local world.
            Ok(()) if self.world().is_some_and(|w| tick >= w.tick()) => {
                self.confirmed.entry(tick).or_default().push((seq, kind))
            }
            Ok(()) => self.events.push(RemoteEvent::CommandDone {
                seq,
                result: Ok(None),
            }),
        }
    }

    /// Simulates confirmed ticks one by one, working out the ids created
    /// by our own commands in each.
    fn advance(&mut self, max_ticks: usize) {
        let Some(me) = self.client.player_id() else {
            return;
        };
        for _ in 0..max_ticks {
            let Some(world) = self.client.world() else {
                return;
            };
            let next = world.tick();
            while let Some(entry) = self.confirmed.first_entry() {
                if *entry.key() >= next {
                    break;
                }
                for (seq, _) in entry.remove() {
                    self.events.push(RemoteEvent::CommandDone {
                        seq,
                        result: Ok(None),
                    });
                }
            }
            let before = self
                .confirmed
                .contains_key(&next)
                .then(|| MaxIds::of(world));
            if self.client.advance(1) == 0 {
                return;
            }
            if self.structural.remove(&next) {
                self.world_changed = true;
            }
            let (Some(before), Some(done)) = (before, self.confirmed.remove(&next)) else {
                continue;
            };
            let world = self.client.world().expect("advanced, so there is a world");
            // Our commands in one tick are applied in the order we sent
            // them and each allocates the next id, so the k-th new node we
            // own belongs to our k-th node command of this tick.
            let mut nodes = world
                .nodes()
                .filter(|(id, n)| id.0 > before.node && n.owner == me)
                .map(|(id, _)| id.0);
            let mut tracks = world
                .tracks()
                .filter(|(id, t)| id.0 > before.track && t.owner == me)
                .map(|(id, _)| id.0);
            let mut trains = world
                .trains()
                .filter(|(id, t)| id.0 > before.train && t.owner == me)
                .map(|(id, _)| id.0);
            for (seq, kind) in done {
                let id = match kind {
                    Creates::Node => nodes.next(),
                    Creates::Track => tracks.next(),
                    Creates::Train => trains.next(),
                    Creates::Nothing => None,
                };
                self.events.push(RemoteEvent::CommandDone {
                    seq,
                    result: Ok(id),
                });
            }
        }
    }

    fn flush(&mut self) {
        let Some(link) = &self.link else {
            return;
        };
        for msg in self.client.drain_outgoing() {
            let _ = link.outbox.send(encode(&msg));
        }
    }

    fn connection_lost(&mut self) {
        let why = self
            .link
            .as_ref()
            .and_then(|l| l.conn.close_reason())
            .map_or_else(|| "the connection closed".to_string(), |e| e.to_string());
        if self.state == RemoteState::Playing {
            self.disconnect(format!("connection lost: {why}"));
        } else {
            self.fail(format!("connection closed before joining: {why}"));
        }
    }

    fn fail(&mut self, reason: String) {
        self.fail_commands(&reason);
        self.shut_down(RemoteState::Closed, format!("Could not join: {reason}"));
        self.events.push(RemoteEvent::Failed { reason });
    }

    fn disconnect(&mut self, reason: String) {
        self.fail_commands(&reason);
        self.shut_down(RemoteState::Closed, format!("Disconnected: {reason}"));
        self.events.push(RemoteEvent::Disconnected { reason });
    }

    fn fail_commands(&mut self, reason: &str) {
        let pending = std::mem::take(&mut self.pending).into_keys();
        let confirmed = std::mem::take(&mut self.confirmed)
            .into_values()
            .flatten()
            .map(|(seq, _)| seq);
        let mut seqs: Vec<u32> = pending.chain(confirmed).collect();
        seqs.sort_unstable();
        for seq in seqs {
            self.events.push(RemoteEvent::CommandDone {
                seq,
                result: Err(format!("not connected ({reason})")),
            });
        }
    }

    fn shut_down(&mut self, state: RemoteState, status: String) {
        self.state = state;
        self.status = status;
        self.ready = None;
        self.link = None;
        self.joining_since = None;
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
    }
}

impl Drop for RemoteClient {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
    }
}

/// Body of the network thread: connect, hand the channels to the owner,
/// then keep the runtime (and so the stream reader and writer) alive until
/// the owner closes or the connection dies.
fn network_thread(
    host: String,
    port: u16,
    verification: ServerVerification,
    ready: std_mpsc::Sender<Result<Link, String>>,
    mut shutdown: oneshot::Receiver<()>,
) {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            let _ = ready.send(Err(format!("starting network runtime: {e}")));
            return;
        }
    };
    rt.block_on(async move {
        let connecting = tokio::time::timeout(
            CONNECT_TIMEOUT,
            connect_any(&host, port, verification),
        );
        let link = tokio::select! {
            r = connecting => r.unwrap_or_else(|_| {
                Err(format!("no answer from {host} port {port} (is the server running and the UDP port open?)"))
            }),
            _ = &mut shutdown => return,
        };
        let ClientLink {
            endpoint,
            conn,
            inbox,
            outbox,
        } = match link {
            Ok(l) => l,
            Err(e) => {
                let _ = ready.send(Err(e));
                return;
            }
        };
        let handed = ready.send(Ok(Link {
            conn: conn.clone(),
            inbox,
            outbox,
        }));
        if handed.is_ok() {
            tokio::select! {
                _ = &mut shutdown => {}
                _ = conn.closed() => {}
            }
        }
        conn.close(0u32.into(), b"bye");
        // Let the close go out and the reader deliver what it has.
        let _ = tokio::time::timeout(Duration::from_secs(1), endpoint.wait_idle()).await;
    });
}

async fn connect_any(
    host: &str,
    port: u16,
    verification: ServerVerification,
) -> Result<ClientLink, String> {
    let mut addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| format!("cannot find {host}: {e}"))?
        .collect();
    // Servers usually bind IPv4 only (0.0.0.0), so try IPv4 first; the
    // sort is stable and keeps the resolver's order otherwise.
    addrs.sort_by_key(SocketAddr::is_ipv6);
    let per_attempt = CONNECT_TIMEOUT / 2;
    let mut last = format!("{host} has no address");
    for addr in addrs {
        let attempt = tokio::time::timeout(per_attempt, ClientLink::connect(addr, verification));
        match attempt.await {
            Err(_) => last = format!("no answer from {addr}"),
            Ok(Ok(link)) => return Ok(link),
            Ok(Err(e)) if e.0.contains("invalid peer certificate") => {
                return Err(format!(
                    "the server at {addr} is not the one the fingerprint belongs to ({e})"
                ))
            }
            Ok(Err(e)) => last = e.0,
        }
    }
    Err(last)
}
