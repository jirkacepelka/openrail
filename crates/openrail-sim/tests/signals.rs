//! Path signals: trains running towards each other on a double-track line
//! must pick free tracks, never share a block and never lock each other.

use std::collections::{BTreeMap, BTreeSet};

use openrail_sim::{Command, Fixed, NodeId, PlayerId, TrackId, TrainId, Vec2, World};

const P: PlayerId = PlayerId(1);

fn node(w: &mut World, x: i32) -> NodeId {
    let pos = Vec2::new(Fixed::from_int(x), Fixed::ZERO);
    w.apply(P, &Command::BuildNode { pos }).unwrap();
    NodeId(w.nodes().map(|(id, _)| id.0).max().unwrap())
}

fn track(w: &mut World, a: NodeId, b: NodeId) -> TrackId {
    w.apply(P, &Command::BuildTrack { a, b }).unwrap();
    TrackId(w.tracks().map(|(id, _)| id.0).max().unwrap())
}

fn train(w: &mut World, on: TrackId, stops: &[NodeId]) -> TrainId {
    w.apply(P, &Command::SpawnTrain { track: on }).unwrap();
    let id = TrainId(w.trains().map(|(id, _)| id.0).max().unwrap());
    let cmd = Command::SetRoute {
        train: id,
        stops: stops.to_vec(),
    };
    w.apply(P, &cmd).unwrap();
    id
}

/// Runs `ticks` ticks, asserting one train per block, and returns how many
/// stops each train reached.
fn run(w: &mut World, ticks: u64) -> BTreeMap<TrainId, u32> {
    let mut reached = BTreeMap::new();
    let mut last = BTreeMap::new();
    for t in 0..ticks {
        w.step();
        let mut seen = BTreeSet::new();
        for (id, train) in w.trains() {
            assert!(
                seen.insert(train.track),
                "two trains on {:?} at tick {t}",
                train.track
            );
            if last.insert(id, train.next_stop) != Some(train.next_stop) {
                *reached.entry(id).or_insert(0) += 1;
            }
        }
    }
    reached
}

#[test]
fn opposing_trains_pass_on_double_track() {
    let mut w = World::new(3);
    let s1 = node(&mut w, 0);
    let mid = node(&mut w, 2000);
    let s2 = node(&mut w, 4000);
    let west = track(&mut w, s1, mid);
    track(&mut w, s1, mid);
    track(&mut w, s2, mid);
    let east = track(&mut w, s2, mid);
    w.apply(P, &Command::BuildStation { node: s1 }).unwrap();
    w.apply(P, &Command::BuildStation { node: s2 }).unwrap();
    let a = train(&mut w, west, &[s2, s1]);
    let b = train(&mut w, east, &[s1, s2]);

    let reached = run(&mut w, 20_000);
    for id in [a, b] {
        assert!(reached[&id] >= 8, "{id:?} reached only {}", reached[&id]);
    }
}

#[test]
fn opposing_trains_wait_instead_of_meeting_on_single_track() {
    // One track between two double-platform stations: the trains must
    // take turns on it and still both keep running.
    let mut w = World::new(4);
    let s1 = node(&mut w, 0);
    let a1 = node(&mut w, 300);
    let b1 = node(&mut w, 2700);
    let s2 = node(&mut w, 3000);
    let p1 = track(&mut w, s1, a1);
    track(&mut w, s1, a1);
    track(&mut w, a1, b1);
    let p2 = track(&mut w, s2, b1);
    track(&mut w, s2, b1);
    w.apply(P, &Command::BuildStation { node: s1 }).unwrap();
    w.apply(P, &Command::BuildStation { node: s2 }).unwrap();
    let a = train(&mut w, p1, &[s2, s1]);
    let b = train(&mut w, p2, &[s1, s2]);

    let reached = run(&mut w, 20_000);
    for id in [a, b] {
        assert!(reached[&id] >= 4, "{id:?} reached only {}", reached[&id]);
    }
}
