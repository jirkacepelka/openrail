//! Real QUIC over loopback: a host with a fast tick, two clients (one
//! pinning the certificate, one in insecure dev mode) building things, and
//! the refusal paths (wrong fingerprint, wrong password).
#![cfg(feature = "quic")]

use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use openrail_net::{
    quic::{run_host, server_endpoint, Fingerprint, NetClient, ServerIdentity, ServerVerification},
    ClientEvent, HostConfig, LockstepHost,
};
use openrail_sim::{Command, Fixed, NodeId, Vec2, World};
use tokio::sync::oneshot;

const TARGET: u64 = 300;

fn node(x: i32, y: i32) -> Command {
    Command::BuildNode {
        pos: Vec2::new(Fixed::from_int(x), Fixed::from_int(y)),
    }
}

/// Runs the client until its world is exactly at `tick`, collecting events.
async fn run_to(c: &mut NetClient, tick: u64, events: &mut Vec<ClientEvent>) {
    loop {
        let now = c.client.world().unwrap().tick();
        if now == tick {
            return;
        }
        events.extend(c.pump((tick - now) as usize));
        if c.client.world().unwrap().tick() < tick && c.client.backlog() == 0 {
            assert!(c.wait().await, "connection lost");
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn quic_loopback_lockstep() {
    tokio::time::timeout(Duration::from_secs(60), scenario())
        .await
        .expect("test timed out");
}

async fn scenario() {
    let identity = ServerIdentity::generate().unwrap();
    let fingerprint = identity.fingerprint();
    let endpoint = server_endpoint("127.0.0.1:0".parse().unwrap(), &identity).unwrap();
    let addr: SocketAddr = endpoint.local_addr().unwrap();
    let cfg = HostConfig {
        password: Some("hunter2".into()),
        hash_interval: 10,
        ..HostConfig::default()
    };
    let host = Arc::new(Mutex::new(LockstepHost::new(World::new(42), cfg)));
    let hashes = Arc::new(Mutex::new(BTreeMap::new()));
    let (stop_tx, stop_rx) = oneshot::channel::<()>();
    let server = tokio::spawn({
        let host = host.clone();
        let hashes = hashes.clone();
        run_host(
            endpoint,
            host,
            Duration::from_millis(5),
            move |h| {
                let w = h.world();
                if w.tick() <= TARGET {
                    hashes.lock().unwrap().insert(w.tick(), w.state_hash());
                }
            },
            async {
                let _ = stop_rx.await;
            },
        )
    });

    let pw = Some("hunter2".to_string());
    let mut ann = NetClient::connect(
        addr,
        ServerVerification::Pinned(fingerprint),
        "ann",
        pw.clone(),
    )
    .await
    .expect("pinned client connects");
    let mut bob = NetClient::connect(
        addr,
        ServerVerification::InsecureAcceptAny,
        "bob",
        pw.clone(),
    )
    .await
    .expect("insecure client connects");
    assert_ne!(ann.client.player_id(), bob.client.player_id());

    let wrong: Fingerprint = "00".repeat(32).parse().unwrap();
    assert!(
        NetClient::connect(addr, ServerVerification::Pinned(wrong), "eve", pw.clone())
            .await
            .is_err(),
        "a wrong fingerprint must be rejected"
    );
    let e = NetClient::connect(addr, ServerVerification::Pinned(fingerprint), "eve", None)
        .await
        .err()
        .expect("no password must be refused");
    assert!(e.to_string().contains("wrong password"), "{e}");

    ann.client.submit(node(0, 0));
    ann.client.submit(node(2000, 0));
    ann.flush();

    let mut ann_events = Vec::new();
    let mut bob_events = Vec::new();
    run_to(&mut ann, 100, &mut ann_events).await;
    // Nodes 1 and 2 are ann's now; bob may not turn hers into a station.
    bob.client.submit(node(0, 1500));
    let bad = bob.client.submit(Command::BuildStation { node: NodeId(1) });
    bob.flush();
    ann.client.submit(Command::BuildTrack {
        a: NodeId(1),
        b: NodeId(2),
    });
    ann.client.submit(Command::BuildStation { node: NodeId(1) });
    ann.client.submit(Command::BuildStation { node: NodeId(2) });
    ann.flush();
    run_to(&mut ann, TARGET, &mut ann_events).await;
    run_to(&mut bob, TARGET, &mut bob_events).await;

    let host_hash = hashes.lock().unwrap()[&TARGET];
    let a = ann.client.world().unwrap();
    let b = bob.client.world().unwrap();
    assert_eq!(a.state_hash(), host_hash);
    assert_eq!(b.state_hash(), host_hash);
    assert_eq!(a.nodes().count(), 3);
    assert_eq!(a.tracks().count(), 1);
    assert_eq!(a.nodes().filter(|(_, n)| n.station).count(), 2);

    let ok = |evs: &[ClientEvent]| {
        evs.iter()
            .filter(|e| matches!(e, ClientEvent::CommandResult { result: Ok(()), .. }))
            .count()
    };
    assert_eq!(ok(&ann_events), 5);
    assert!(bob_events.iter().any(|e| matches!(
        e,
        ClientEvent::CommandResult { client_seq, result: Err(_), .. } if *client_seq == bad
    )));
    assert!(!ann_events
        .iter()
        .chain(&bob_events)
        .any(|e| matches!(e, ClientEvent::Desync { .. })));

    // Let hash reports for the last ticks arrive, then check the host saw
    // no desync and lists both players.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let players = host.lock().unwrap().players();
    assert_eq!(players.len(), 2);
    assert!(players.iter().all(|p| p.connected && p.desyncs == 0));

    ann.close().await;
    bob.close().await;
    let _ = stop_tx.send(());
    server.await.unwrap();
}

/// The host keeps its tick rate even when the OS wakes it late: with a
/// 2 ms period and Windows' ~15.6 ms timer granularity, a host that waits
/// one period per wake-up would manage about 64 ticks a second.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn host_keeps_its_tick_rate_with_coarse_timers() {
    let identity = ServerIdentity::generate().unwrap();
    let endpoint = server_endpoint("127.0.0.1:0".parse().unwrap(), &identity).unwrap();
    let host = Arc::new(Mutex::new(LockstepHost::new(
        World::new(1),
        HostConfig::default(),
    )));
    let (stop_tx, stop_rx) = oneshot::channel::<()>();
    let started = std::time::Instant::now();
    let server = tokio::spawn(run_host(
        endpoint,
        host.clone(),
        Duration::from_millis(2),
        |_| {},
        async {
            let _ = stop_rx.await;
        },
    ));
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let ticks = host.lock().unwrap().world().tick();
    let elapsed = started.elapsed();
    let _ = stop_tx.send(());
    server.await.unwrap();
    let expected = elapsed.as_millis() as u64 / 2;
    assert!(
        ticks >= expected / 2 && ticks <= expected + 5,
        "{ticks} ticks in {elapsed:?}, expected about {expected}"
    );
}
