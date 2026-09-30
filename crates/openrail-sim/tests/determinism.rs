//! Phase 0 gate: the same replay gives the same state hash on every run
//! and every platform. CI runs this on Linux and Windows.

use openrail_sim::{Command, Fixed, NodeId, PlayerId, Replay, TrackId, TrainId, Vec2, World};

const P1: PlayerId = PlayerId(1);
const P2: PlayerId = PlayerId(2);

/// Hash of `scenario()` after `GATE_TICKS` ticks. If a change to the
/// simulation moves this value on purpose, update it in the same commit
/// and say why in the message. If it moves by accident, that is a bug.
const GOLDEN_HASH: u64 = 0x2380883f2d750522;
const GATE_TICKS: u64 = 10_000;

fn pos(x: i32, y: i32) -> Vec2 {
    Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
}

/// A ring line with four stations and three P1 trains following each
/// other, a separate P2 shuttle, several rejected commands and a removal.
fn scenario() -> Replay {
    let mut r = Replay::new(0x0E7_2A11);
    // Ids are allocated in order: nodes 1..=6, tracks 7..=11, trains 12..
    r.push(0, P1, Command::BuildNode { pos: pos(0, 0) });
    r.push(0, P1, Command::BuildNode { pos: pos(3000, 0) });
    r.push(
        0,
        P1,
        Command::BuildNode {
            pos: pos(3000, 2000),
        },
    );
    r.push(0, P1, Command::BuildNode { pos: pos(0, 2000) });
    r.push(
        0,
        P2,
        Command::BuildNode {
            pos: pos(-800, 333),
        },
    );
    r.push(
        0,
        P2,
        Command::BuildNode {
            pos: pos(-801, -4127),
        },
    );
    r.push(
        1,
        P1,
        Command::BuildTrack {
            a: NodeId(1),
            b: NodeId(2),
        },
    );
    r.push(
        1,
        P1,
        Command::BuildTrack {
            a: NodeId(2),
            b: NodeId(3),
        },
    );
    r.push(
        1,
        P1,
        Command::BuildTrack {
            a: NodeId(3),
            b: NodeId(4),
        },
    );
    r.push(
        1,
        P1,
        Command::BuildTrack {
            a: NodeId(4),
            b: NodeId(1),
        },
    );
    r.push(
        1,
        P2,
        Command::BuildTrack {
            a: NodeId(5),
            b: NodeId(6),
        },
    );
    for n in 1..=4 {
        r.push(1, P1, Command::BuildStation { node: NodeId(n) });
    }
    r.push(2, P1, Command::SpawnTrain { track: TrackId(7) });
    r.push(2, P1, Command::SpawnTrain { track: TrackId(9) });
    r.push(3, P1, route(12, &[2, 3, 4, 1]));
    r.push(3, P1, route(13, &[4, 1, 2, 3]));
    r.push(40, P2, Command::SpawnTrain { track: TrackId(11) });
    r.push(41, P2, Command::SpawnTrain { track: TrackId(7) }); // occupied
    r.push(42, P2, route(14, &[5])); // not a station
    r.push(600, P1, Command::SpawnTrain { track: TrackId(8) });
    r.push(601, P1, route(15, &[3, 4, 1, 2]));
    r.push(2500, P2, Command::RemoveTrain { train: TrainId(12) }); // not P2's
    r.push(8000, P1, Command::RemoveTrain { train: TrainId(13) });
    r
}

fn route(train: u32, stops: &[u32]) -> Command {
    Command::SetRoute {
        train: TrainId(train),
        stops: stops.iter().map(|&n| NodeId(n)).collect(),
    }
}

#[test]
fn same_replay_same_hash() {
    let a = scenario().run(GATE_TICKS);
    let b = scenario().run(GATE_TICKS);
    assert_eq!(a.state_hash(), b.state_hash());
    assert_eq!(a, b);
}

#[test]
fn golden_hash_is_stable_across_platforms() {
    let hash = scenario().run(GATE_TICKS).state_hash();
    assert_eq!(hash, GOLDEN_HASH, "state hash changed: got {hash:#018x}");
}

#[test]
fn save_and_load_continues_identically() {
    let r = scenario();
    let mut straight = World::new(r.seed);
    r.run_on(&mut straight, GATE_TICKS);

    let mut first_half = World::new(r.seed);
    r.run_on(&mut first_half, 4321);
    let mut resumed = World::load(&first_half.save()).expect("save loads");
    r.run_on(&mut resumed, GATE_TICKS);

    assert_eq!(resumed.state_hash(), straight.state_hash());
}

#[test]
fn different_seed_diverges() {
    let mut other = scenario();
    other.seed += 1;
    assert_ne!(
        scenario().run(GATE_TICKS).state_hash(),
        other.run(GATE_TICKS).state_hash()
    );
}

#[test]
fn rejected_commands_leave_world_untouched() {
    let mut w = scenario().run(100);
    let before = w.clone();
    assert!(w
        .apply(
            P1,
            &Command::BuildTrack {
                a: NodeId(1),
                b: NodeId(1)
            }
        )
        .is_err());
    assert!(w
        .apply(
            P1,
            &Command::BuildTrack {
                a: NodeId(1),
                b: NodeId(404)
            }
        )
        .is_err());
    assert!(w
        .apply(P2, &Command::RemoveTrain { train: TrainId(12) })
        .is_err());
    assert!(w.apply(P1, &route(12, &[5])).is_err());
    assert!(w
        .apply(P1, &Command::SpawnTrain { track: TrackId(7) })
        .is_err());
    assert_eq!(w, before);
}

#[test]
fn trains_stay_on_their_track_and_under_max_speed() {
    let r = scenario();
    let mut w = World::new(r.seed);
    for t in (0..GATE_TICKS).step_by(50) {
        r.run_on(&mut w, t + 50);
        let lengths: Vec<_> = w.tracks().map(|(id, tr)| (id, tr.length)).collect();
        for (_, train) in w.trains() {
            let len = lengths.iter().find(|(id, _)| *id == train.track).unwrap().1;
            assert!(train.offset >= Fixed::ZERO && train.offset <= len);
            assert!(train.speed <= openrail_sim::Train::MAX_SPEED);
        }
    }
    assert_eq!(w.trains().count(), 3);
}

#[test]
fn signals_keep_one_train_per_block_and_trains_keep_moving() {
    let r = scenario();
    let mut w = World::new(r.seed);
    let mut stops_reached = std::collections::BTreeMap::new();
    let mut last_stop = std::collections::BTreeMap::new();
    let mut ever_held = false;
    for t in 0..GATE_TICKS {
        r.run_on(&mut w, t + 1);
        let mut seen = std::collections::BTreeSet::new();
        for (id, train) in w.trains() {
            assert!(
                seen.insert(train.track),
                "two trains on track {:?} at tick {t}",
                train.track
            );
            ever_held |= train.held;
            if last_stop.insert(id, train.next_stop) != Some(train.next_stop) {
                *stops_reached.entry(id).or_insert(0u32) += 1;
            }
        }
    }
    assert!(ever_held, "no train was ever held at a signal");
    for id in [12, 15] {
        let n = stops_reached[&TrainId(id)];
        assert!(n >= 5, "train {id} reached only {n} stops");
    }
}
