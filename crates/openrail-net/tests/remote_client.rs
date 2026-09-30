//! The non-blocking [`RemoteClient`] against an in-process host over real
//! QUIC: joining, id reporting for chained commands while another player
//! builds at the same time, a train that moves, and the failure paths.
#![cfg(feature = "quic")]

use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use openrail_net::{
    quic::{run_host, server_endpoint, Fingerprint, ServerIdentity, ServerVerification},
    remote::{verification_from_str, RemoteClient, RemoteEvent, RemoteState},
    HostConfig, LockstepHost,
};
use openrail_sim::{Command, Fixed, NodeId, PlayerId, TrackId, TrainId, Vec2, World};
use tokio::sync::oneshot;

fn pos(x: i32, y: i32) -> Vec2 {
    Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
}

/// Polls like a game loop would until `done` holds, collecting events.
async fn poll_until(
    c: &mut RemoteClient,
    events: &mut Vec<RemoteEvent>,
    what: &str,
    mut done: impl FnMut(&RemoteClient, &[RemoteEvent]) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done(c, events) {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        events.extend(c.poll(100));
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
}

fn result_of(events: &[RemoteEvent], seq: u32) -> Option<Result<Option<u32>, String>> {
    events.iter().find_map(|e| match e {
        RemoteEvent::CommandDone { seq: s, result } if *s == seq => Some(result.clone()),
        _ => None,
    })
}

/// Waits for the results of `seqs` and returns the created ids.
async fn ids_of(c: &mut RemoteClient, events: &mut Vec<RemoteEvent>, seqs: &[u32]) -> Vec<u32> {
    poll_until(c, events, "command results", |_, evs| {
        seqs.iter().all(|s| result_of(evs, *s).is_some())
    })
    .await;
    seqs.iter()
        .map(|s| {
            result_of(events, *s)
                .unwrap()
                .expect("command accepted")
                .expect("command created something")
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_client_builds_a_line_and_the_train_moves() {
    tokio::time::timeout(Duration::from_secs(90), scenario())
        .await
        .expect("test timed out");
}

async fn scenario() {
    let identity = ServerIdentity::generate().unwrap();
    let fingerprint = identity.fingerprint();
    let endpoint = server_endpoint("127.0.0.1:0".parse().unwrap(), &identity).unwrap();
    let addr: SocketAddr = endpoint.local_addr().unwrap();
    let cfg = HostConfig {
        password: Some("pw".into()),
        hash_interval: 10,
        ..HostConfig::default()
    };
    let host = Arc::new(Mutex::new(LockstepHost::new(World::new(7), cfg)));
    let (stop_tx, stop_rx) = oneshot::channel::<()>();
    let server = tokio::spawn(run_host(
        endpoint,
        host.clone(),
        Duration::from_millis(2),
        |_| {},
        async {
            let _ = stop_rx.await;
        },
    ));
    let port = addr.port();
    let pw = Some("pw".to_string());

    // Joining, pinned and insecure.
    let pinned = verification_from_str(&fingerprint.to_string()).unwrap();
    assert!(matches!(pinned, ServerVerification::Pinned(f) if f == fingerprint));
    let mut ann = RemoteClient::connect("127.0.0.1", port, pinned, "ann", pw.clone()).unwrap();
    let insecure = verification_from_str("").unwrap();
    let mut bob = RemoteClient::connect("127.0.0.1", port, insecure, "bob", pw.clone()).unwrap();
    assert_eq!(ann.state(), RemoteState::Connecting);
    assert!(ann.world().is_none());
    let (mut ann_ev, mut bob_ev) = (Vec::new(), Vec::new());
    for (c, evs) in [(&mut ann, &mut ann_ev), (&mut bob, &mut bob_ev)] {
        poll_until(c, evs, "join", |c, _| c.state() == RemoteState::Playing).await;
        assert!(evs.contains(&RemoteEvent::Connected));
        assert!(evs.iter().any(|e| matches!(e, RemoteEvent::Joined { .. })));
        assert!(c.world().is_some());
    }
    let me = ann.player_id().unwrap();
    assert_ne!(Some(me), bob.player_id());
    assert!(ann.status().contains("Playing"), "{}", ann.status());

    // Both build nodes at the same time, so their commands interleave in
    // the same ticks; every reported id must still be the right node.
    let a_pts = [(0, 0), (2000, 0), (4000, 0)];
    let b_pts = [(0, 3000), (500, 3000)];
    let a_seqs: Vec<u32> = a_pts
        .iter()
        .map(|&(x, y)| ann.submit(Command::BuildNode { pos: pos(x, y) }).unwrap())
        .collect();
    let b_seqs: Vec<u32> = b_pts
        .iter()
        .map(|&(x, y)| bob.submit(Command::BuildNode { pos: pos(x, y) }).unwrap())
        .collect();
    let a_ids = ids_of(&mut ann, &mut ann_ev, &a_seqs).await;
    let b_ids = ids_of(&mut bob, &mut bob_ev, &b_seqs).await;
    for (ids, pts, c) in [(&a_ids, &a_pts[..], &ann), (&b_ids, &b_pts[..], &bob)] {
        let w = c.world().unwrap();
        for (id, &(x, y)) in ids.iter().zip(pts) {
            let (_, node) = w.nodes().find(|(n, _)| n.0 == *id).expect("node exists");
            assert_eq!(node.pos, pos(x, y), "node {id}");
            assert_eq!(Some(node.owner), c.player_id());
        }
    }
    assert!(ann_ev.contains(&RemoteEvent::WorldChanged));

    // Chain tracks between the reported ids, stations at the ends.
    let [n0, n1, n2] = [a_ids[0], a_ids[1], a_ids[2]].map(NodeId);
    let t_seqs = [
        ann.submit(Command::BuildTrack { a: n0, b: n1 }).unwrap(),
        ann.submit(Command::BuildTrack { a: n1, b: n2 }).unwrap(),
    ];
    let s_seqs = [
        ann.submit(Command::BuildStation { node: n0 }).unwrap(),
        ann.submit(Command::BuildStation { node: n2 }).unwrap(),
    ];
    let tracks = ids_of(&mut ann, &mut ann_ev, &t_seqs).await;
    poll_until(&mut ann, &mut ann_ev, "stations", |_, evs| {
        s_seqs.iter().all(|s| result_of(evs, *s) == Some(Ok(None)))
    })
    .await;
    {
        let w = ann.world().unwrap();
        let t = w.tracks().find(|(id, _)| id.0 == tracks[0]).unwrap().1;
        assert_eq!((t.a, t.b), (n0, n1));
    }

    // Someone else's node cannot become bob's station.
    let bad = bob.submit(Command::BuildStation { node: n0 }).unwrap();
    poll_until(&mut bob, &mut bob_ev, "rejection", |_, evs| {
        result_of(evs, bad).is_some()
    })
    .await;
    assert!(result_of(&bob_ev, bad).unwrap().is_err());

    // A train on the first track, routed to the far end, has to move there.
    let spawn = ann
        .submit(Command::SpawnTrain {
            track: TrackId(tracks[0]),
        })
        .unwrap();
    let train = ids_of(&mut ann, &mut ann_ev, &[spawn]).await[0];
    let route = ann
        .submit(Command::SetRoute {
            train: TrainId(train),
            stops: vec![n0, n2],
        })
        .unwrap();
    let start = ann.world().unwrap().tick();
    poll_until(&mut ann, &mut ann_ev, "the train to travel", |c, _| {
        let w = c.world().unwrap();
        w.train_position(TrainId(train))
            .is_some_and(|p| p.x > Fixed::from_int(3000))
    })
    .await;
    assert_eq!(result_of(&ann_ev, route), Some(Ok(None)));
    assert!(ann.world().unwrap().tick() > start);
    // Bob follows the same game.
    poll_until(&mut bob, &mut bob_ev, "bob to see the train", |c, _| {
        c.world().unwrap().trains().count() == 1
    })
    .await;
    assert!(!ann_ev
        .iter()
        .chain(&bob_ev)
        .any(|e| matches!(e, RemoteEvent::Desync { .. })));
    // The company balance belongs to the joined player, not to player 0.
    let w = ann.world().unwrap();
    assert!(w.company(me).is_some());
    assert!(w.company(PlayerId(0)).is_none());

    // Failure paths are reported, never block, and end in Closed.
    let mut eve = RemoteClient::connect("127.0.0.1", port, insecure, "eve", None).unwrap();
    let mut eve_ev = Vec::new();
    poll_until(&mut eve, &mut eve_ev, "refusal", |c, _| {
        c.state() == RemoteState::Closed
    })
    .await;
    assert!(
        matches!(&eve_ev[..], [.., RemoteEvent::Failed { reason }] if reason.contains("wrong password")),
        "{eve_ev:?}"
    );
    let wrong: Fingerprint = "ab".repeat(32).parse().unwrap();
    let mut mal = RemoteClient::connect(
        "127.0.0.1",
        port,
        ServerVerification::Pinned(wrong),
        "mal",
        pw.clone(),
    )
    .unwrap();
    let mut mal_ev = Vec::new();
    poll_until(&mut mal, &mut mal_ev, "certificate failure", |c, _| {
        c.state() == RemoteState::Closed
    })
    .await;
    assert!(
        matches!(&mal_ev[..], [RemoteEvent::Failed { reason }] if reason.contains("fingerprint")),
        "{mal_ev:?}"
    );
    assert!(verification_from_str("not hex").is_err());

    // Commands still in flight when leaving are dropped, not reported.
    ann.submit(Command::BuildNode { pos: pos(9, 9) });
    ann.leave();
    assert_eq!(ann.state(), RemoteState::Closed);
    assert!(ann.submit(Command::BuildNode { pos: pos(9, 9) }).is_none());
    assert!(ann.poll(10).is_empty());
    assert!(ann.world().is_some(), "the last world stays readable");
    poll_until(&mut bob, &mut bob_ev, "ann to leave", |_, evs| {
        evs.contains(&RemoteEvent::PlayerLeft { player_id: me })
    })
    .await;

    drop(bob);
    let _ = stop_tx.send(());
    server.await.unwrap();
}
