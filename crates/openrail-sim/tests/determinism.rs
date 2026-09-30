//! Phase 0 gate: the same replay gives the same state hash on every run
//! and every platform. CI runs this on Linux and Windows.

use openrail_sim::{Command, Fixed, NodeId, PlayerId, Replay, TrackId, TrainId, Vec2, World};

const P1: PlayerId = PlayerId(1);
const P2: PlayerId = PlayerId(2);

/// Hash of `scenario()` after `GATE_TICKS` ticks. If a change to the
/// simulation moves this value on purpose, update it in the same commit
/// and say why in the message. If it moves by accident, that is a bug.
const GOLDEN_HASH: u64 = 0x02459a2dfaf73c95;
const GATE_TICKS: u64 = 10_000;

fn pos(x: i32, y: i32) -> Vec2 {
    Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
}

/// Two players, four tracks of different lengths, trains spawned at
/// different times, one invalid command and one removal.
fn scenario() -> Replay {
    let mut r = Replay::new(0x0E7_2A11);
    // Ids are allocated in order: nodes 1..=5, then tracks 6..=9.
    r.push(0, P1, Command::BuildNode { pos: pos(0, 0) });
    r.push(0, P1, Command::BuildNode { pos: pos(2000, 0) });
    r.push(
        0,
        P1,
        Command::BuildNode {
            pos: pos(2000, 1500),
        },
    );
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
        P2,
        Command::BuildTrack {
            a: NodeId(4),
            b: NodeId(5),
        },
    );
    r.push(
        1,
        P2,
        Command::BuildTrack {
            a: NodeId(1),
            b: NodeId(4),
        },
    );
    r.push(2, P1, Command::SpawnTrain { track: TrackId(6) });
    r.push(2, P1, Command::SpawnTrain { track: TrackId(7) });
    r.push(40, P2, Command::SpawnTrain { track: TrackId(8) });
    r.push(41, P2, Command::SpawnTrain { track: TrackId(99) }); // rejected
    r.push(700, P2, Command::SpawnTrain { track: TrackId(9) });
    r.push(900, P1, Command::SpawnTrain { track: TrackId(6) });
    r.push(2500, P2, Command::RemoveTrain { train: TrainId(10) }); // not P2's
    r.push(5000, P1, Command::RemoveTrain { train: TrainId(11) });
    r
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
        .apply(P2, &Command::RemoveTrain { train: TrainId(10) })
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
    assert_eq!(w.trains().count(), 4);
}
