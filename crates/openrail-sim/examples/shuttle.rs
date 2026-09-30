//! Prints one train shuttling on a 2 km track, once per simulated minute.

use openrail_sim::{
    Command, Fixed, NodeId, PlayerId, TrackId, TrainId, Vec2, World, TICKS_PER_SECOND,
};

fn main() {
    let p = PlayerId(1);
    let mut w = World::new(1);
    let at = |x| Vec2::new(Fixed::from_int(x), Fixed::ZERO);
    w.apply(p, &Command::BuildNode { pos: at(0) }).unwrap();
    w.apply(p, &Command::BuildNode { pos: at(2000) }).unwrap();
    w.apply(
        p,
        &Command::BuildTrack {
            a: NodeId(1),
            b: NodeId(2),
        },
    )
    .unwrap();
    w.apply(p, &Command::SpawnTrain { track: TrackId(3) })
        .unwrap();
    for minute in 1..=10 {
        for _ in 0..60 * TICKS_PER_SECOND {
            w.step();
        }
        let (_, t) = w.trains().next().unwrap();
        let pos = w.train_position(TrainId(4)).unwrap();
        println!(
            "min {minute:2}: x = {:7.1} m, speed = {:5.2} m/s, dwell = {}",
            pos.x.to_f64_lossy(),
            t.speed.to_f64_lossy(),
            t.dwell
        );
    }
    println!("hash {:#018x}", w.state_hash());
}
