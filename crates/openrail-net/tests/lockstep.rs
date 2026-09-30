//! Lockstep over in-memory channels: a host and three clients with uneven
//! latency and frame rates, random commands for 3000 ticks, one client
//! joining late from a snapshot. Every world must end identical.

use std::collections::VecDeque;

use openrail_net::{
    ClientEvent, ClientMsg, ConnId, HostConfig, HostOutput, LockstepClient, LockstepHost, ServerMsg,
};
use openrail_sim::{Command, Fixed, NodeId, PlayerId, SimRng, TrackId, TrainId, Vec2, World};

const TICKS: u64 = 3000;

/// One simulated connection with per-direction latency (in host ticks).
/// Messages on a stream never overtake each other.
struct Peer {
    conn: ConnId,
    client: LockstepClient,
    latency: u64,
    to_client: VecDeque<(u64, ServerMsg)>,
    to_host: VecDeque<(u64, ClientMsg)>,
    submitted: u32,
    accepted: u32,
    desyncs_seen: u32,
    /// When set, the next bundle with commands is tampered with, to test
    /// desync detection and recovery.
    corrupt_next_bundle: bool,
}

impl Peer {
    fn new(conn: u64, name: &str, latency: u64) -> Self {
        Peer {
            conn: ConnId(conn),
            client: LockstepClient::new(name, Some("pw".into())),
            latency,
            to_client: VecDeque::new(),
            to_host: VecDeque::new(),
            submitted: 0,
            accepted: 0,
            desyncs_seen: 0,
            corrupt_next_bundle: false,
        }
    }

    fn arrival(queue_last: Option<u64>, now: u64, latency: u64, rng: &mut SimRng) -> u64 {
        let t = now + latency + rng.below(3);
        t.max(queue_last.unwrap_or(0))
    }
}

struct Net {
    host: LockstepHost,
    peers: Vec<Peer>,
    rng: SimRng,
    now: u64,
}

impl Net {
    fn route_host_output(&mut self) {
        for out in self.host.drain_output() {
            match out {
                HostOutput::Send { to, msg } => {
                    for p in self.peers.iter_mut().filter(|p| to.contains(&p.conn)) {
                        let mut msg = msg.clone();
                        if let ServerMsg::Tick(b) = &mut msg {
                            if p.corrupt_next_bundle && !b.commands.is_empty() {
                                p.corrupt_next_bundle = false;
                                b.commands
                                    .push((PlayerId(99), Command::BuildNode { pos: pos(1, 1) }));
                            }
                        }
                        let at = Peer::arrival(
                            p.to_client.back().map(|m| m.0),
                            self.now,
                            p.latency,
                            &mut self.rng,
                        );
                        p.to_client.push_back((at, msg));
                    }
                }
                HostOutput::Disconnect(c) => panic!("host disconnected {c:?}"),
            }
        }
    }

    /// One host tick of wall time: deliver due messages, let clients run a
    /// random number of frames, execute one host tick.
    fn step(&mut self, submit: bool) {
        // Client -> host.
        for i in 0..self.peers.len() {
            while self.peers[i]
                .to_host
                .front()
                .is_some_and(|(t, _)| *t <= self.now)
            {
                let (_, msg) = self.peers[i].to_host.pop_front().unwrap();
                let conn = self.peers[i].conn;
                self.host.handle(conn, msg);
            }
        }
        self.route_host_output();

        // Host -> clients, then client frames.
        for p in &mut self.peers {
            while p.to_client.front().is_some_and(|(t, _)| *t <= self.now) {
                let (_, msg) = p.to_client.pop_front().unwrap();
                p.client.handle(msg);
            }
            // Uneven frame pacing: sometimes a stall, sometimes catch-up.
            let budget = self.rng.below(4) as usize;
            p.client.advance(budget);
            if submit && p.client.world().is_some() && self.rng.below(4) == 0 {
                let me = p.client.player_id().unwrap();
                let cmd = random_command(p.client.world().unwrap(), me, &mut self.rng);
                p.client.submit(cmd);
                p.submitted += 1;
            }
            for ev in p.client.drain_events() {
                match ev {
                    ClientEvent::CommandResult { result: Ok(()), .. } => p.accepted += 1,
                    ClientEvent::Desync { .. } => p.desyncs_seen += 1,
                    ClientEvent::ProtocolError(e) | ClientEvent::Refused { reason: e } => {
                        panic!("{:?}: {e}", p.conn)
                    }
                    _ => {}
                }
            }
            for msg in p.client.drain_outgoing() {
                let at = Peer::arrival(
                    p.to_host.back().map(|m| m.0),
                    self.now,
                    p.latency,
                    &mut self.rng,
                );
                p.to_host.push_back((at, msg));
            }
        }

        self.host.tick();
        self.route_host_output();
        self.now += 1;
    }

    /// Stops the host and lets every message arrive and every client catch
    /// up.
    fn settle(&mut self) {
        for _ in 0..200 {
            for p in &mut self.peers {
                while let Some((_, msg)) = p.to_client.pop_front() {
                    p.client.handle(msg);
                }
                p.client.advance(usize::MAX);
                for msg in p.client.drain_outgoing() {
                    p.to_host.push_back((0, msg));
                }
                for ev in p.client.drain_events() {
                    if let ClientEvent::Desync { .. } = ev {
                        p.desyncs_seen += 1;
                    }
                }
            }
            let mut any = false;
            for i in 0..self.peers.len() {
                while let Some((_, msg)) = self.peers[i].to_host.pop_front() {
                    any = true;
                    let conn = self.peers[i].conn;
                    self.host.handle(conn, msg);
                }
            }
            self.route_host_output();
            if !any && self.peers.iter().all(|p| p.to_client.is_empty()) {
                return;
            }
        }
        panic!("did not settle");
    }
}

fn pos(x: i32, y: i32) -> Vec2 {
    Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
}

fn pick<T: Copy>(items: &[T], rng: &mut SimRng) -> Option<T> {
    (!items.is_empty()).then(|| items[rng.below(items.len() as u64) as usize])
}

/// A plausible command from what the client sees. Some are invalid on
/// purpose (other players' nodes, occupied tracks, stale ids): the host
/// must drop those without anyone desyncing.
fn random_command(world: &World, me: PlayerId, rng: &mut SimRng) -> Command {
    let nodes: Vec<NodeId> = world.nodes().map(|(id, _)| id).collect();
    let stations: Vec<NodeId> = world
        .nodes()
        .filter(|(_, n)| n.station)
        .map(|(id, _)| id)
        .collect();
    let tracks: Vec<TrackId> = world.tracks().map(|(id, _)| id).collect();
    let trains: Vec<TrainId> = world.trains().map(|(id, _)| id).collect();
    let mine: Vec<TrainId> = world
        .trains()
        .filter(|(_, t)| t.owner == me)
        .map(|(id, _)| id)
        .collect();
    let roll = rng.below(100);
    // A small area keeps track cheap, so companies can still afford trains.
    let fallback = Command::BuildNode {
        pos: pos(rng.below(400) as i32, rng.below(400) as i32),
    };
    match roll {
        0..=24 => fallback,
        25..=49 => match (pick(&nodes, rng), pick(&nodes, rng)) {
            (Some(a), Some(b)) => Command::BuildTrack { a, b },
            _ => fallback,
        },
        50..=62 => match pick(&nodes, rng) {
            Some(node) => Command::BuildStation { node },
            None => fallback,
        },
        63..=77 => match pick(&tracks, rng) {
            Some(track) => Command::SpawnTrain { track },
            None => fallback,
        },
        78..=94 => match (pick(&mine, rng), stations.len() >= 2) {
            (Some(train), true) => {
                let n = 2 + rng.below(3) as usize;
                let stops = (0..n).filter_map(|_| pick(&stations, rng)).collect();
                Command::SetRoute { train, stops }
            }
            _ => fallback,
        },
        _ => match pick(&trains, rng) {
            Some(train) => Command::RemoveTrain { train },
            None => fallback,
        },
    }
}

fn new_net(seed: u64) -> Net {
    let cfg = HostConfig {
        password: Some("pw".into()),
        input_delay: 2,
        hash_interval: 25,
        ..HostConfig::default()
    };
    Net {
        host: LockstepHost::new(World::new(seed), cfg),
        peers: vec![Peer::new(1, "ann", 1), Peer::new(2, "bob", 4)],
        rng: SimRng::new(seed ^ 0x5eed),
        now: 0,
    }
}

#[test]
fn three_clients_stay_in_sync_for_3000_ticks_with_a_late_joiner() {
    let mut net = new_net(0xC0FFEE);
    let mut late_joined_at = None;
    while net.now < TICKS {
        if net.now == 1000 {
            net.peers.push(Peer::new(3, "cid", 7));
            late_joined_at = Some(net.now);
        }
        net.step(true);
    }
    net.settle();

    let host_world = net.host.world();
    assert_eq!(host_world.tick(), TICKS);
    let expected = host_world.state_hash();
    for p in &net.peers {
        let w = p.client.world().expect("joined");
        assert_eq!(w.tick(), TICKS, "{:?} did not catch up", p.conn);
        assert_eq!(w.state_hash(), expected, "{:?} desynced", p.conn);
        assert_eq!(w, host_world);
        assert_eq!(p.desyncs_seen, 0, "{:?} saw a desync", p.conn);
        assert!(
            p.accepted > 20,
            "{:?}: only {} accepted",
            p.conn,
            p.accepted
        );
        assert!(p.accepted < p.submitted, "some commands should be rejected");
    }
    for p in &net.peers {
        println!(
            "{:?}: submitted {} accepted {}",
            p.conn, p.submitted, p.accepted
        );
    }
    println!(
        "nodes {} tracks {} trains {}",
        host_world.nodes().count(),
        host_world.tracks().count(),
        host_world.trains().count()
    );
    assert!(net.host.players().iter().all(|p| p.desyncs == 0));
    assert_eq!(net.host.players().len(), 3);
    assert!(late_joined_at.is_some());
    // The game did something worth checking.
    assert!(host_world.trains().count() > 0);
    assert!(host_world.nodes().filter(|(_, n)| n.station).count() > 0);
}

#[test]
fn a_corrupted_client_is_detected_and_resynced() {
    let mut net = new_net(7);
    while net.now < 400 {
        if net.now == 200 {
            net.peers[1].corrupt_next_bundle = true;
        }
        net.step(true);
    }
    net.settle();

    let expected = net.host.world().state_hash();
    for p in &net.peers {
        assert_eq!(p.client.world().unwrap().state_hash(), expected);
    }
    assert_eq!(net.peers[0].desyncs_seen, 0);
    assert!(net.peers[1].desyncs_seen >= 1);
    let bob = &net.host.players()[1];
    assert_eq!(bob.name, "bob");
    assert!(bob.desyncs >= 1);
}
