//! Headless test client: connects to a server, builds a small line with a
//! train, then keeps following the game and printing its state hash.
//!
//! ```sh
//! cargo run -p openrail-net --example bot -- 127.0.0.1:7878 \
//!     --fingerprint <hex from the server log> [--name bot] [--password pw] [--ticks 600]
//! cargo run -p openrail-net --example bot -- 127.0.0.1:7878 --insecure   # dev only
//! ```

use std::{net::SocketAddr, time::Duration};

use openrail_net::{
    quic::{NetClient, ServerVerification},
    ClientEvent,
};
use openrail_sim::{Command, Fixed, NodeId, Vec2, World, TICKS_PER_SECOND};

struct Args {
    addr: SocketAddr,
    verification: ServerVerification,
    name: String,
    password: Option<String>,
    ticks: u64,
}

fn parse_args() -> Result<Args, String> {
    let mut args = std::env::args().skip(1);
    let mut addr = None;
    let mut verification = None;
    let mut name = "bot".to_string();
    let mut password = None;
    let mut ticks = 600;
    while let Some(a) = args.next() {
        let mut value = || args.next().ok_or(format!("{a} needs a value"));
        match a.as_str() {
            "--fingerprint" => {
                let f = value()?.parse().map_err(|e| format!("{e}"))?;
                verification = Some(ServerVerification::Pinned(f));
            }
            "--insecure" => verification = Some(ServerVerification::InsecureAcceptAny),
            "--name" => name = value()?,
            "--password" => password = Some(value()?),
            "--ticks" => ticks = value()?.parse().map_err(|e| format!("--ticks: {e}"))?,
            other => addr = Some(other.parse().map_err(|e| format!("address {other}: {e}"))?),
        }
    }
    Ok(Args {
        addr: addr.ok_or("usage: bot <addr> (--fingerprint <hex> | --insecure) [--name n] [--password p] [--ticks n]")?,
        verification: verification.ok_or("pass --fingerprint <hex> or --insecure")?,
        name,
        password,
        ticks,
    })
}

fn pos(x: i32, y: i32) -> Vec2 {
    Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
}

/// Ids of the newest `n` nodes this player owns.
fn my_nodes(world: &World, me: openrail_sim::PlayerId, n: usize) -> Vec<NodeId> {
    let mine: Vec<NodeId> = world
        .nodes()
        .filter(|(_, node)| node.owner == me)
        .map(|(id, _)| id)
        .collect();
    mine[mine.len().saturating_sub(n)..].to_vec()
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let mut net =
        match NetClient::connect(args.addr, args.verification, &args.name, args.password).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        };
    let me = net.client.player_id().unwrap();
    let start = net.client.world().unwrap().tick();
    println!("joined as {me:?} at tick {start}, rtt {:?}", net.rtt());

    // Offset the line by player id so several bots do not overlap.
    let y = i32::from(me.0) * 500;
    net.client.submit(Command::BuildNode { pos: pos(0, y) });
    net.client.submit(Command::BuildNode { pos: pos(2000, y) });
    let mut stage = 0;
    let mut last_report = start;
    let mut frame =
        tokio::time::interval(Duration::from_millis(1000 / u64::from(TICKS_PER_SECOND)));

    loop {
        frame.tick().await;
        // Catch up at most a few seconds of game per frame.
        for ev in net.pump(10 * TICKS_PER_SECOND as usize) {
            match ev {
                ClientEvent::CommandResult {
                    client_seq, result, ..
                } => {
                    println!("command {client_seq}: {result:?}")
                }
                ClientEvent::Kicked { reason } => {
                    println!("kicked: {reason}");
                    return;
                }
                ClientEvent::Chat { from, text } => println!("<{from:?}> {text}"),
                other => println!("{other:?}"),
            }
        }
        let world = net.client.world().unwrap();
        let tick = world.tick();
        if tick >= last_report + 5 * u64::from(TICKS_PER_SECOND) {
            last_report = tick;
            println!(
                "tick {tick} hash {:016x} trains {}",
                world.state_hash(),
                world.trains().count()
            );
        }
        // Once the two nodes exist, connect them, make stations, run a train.
        let nodes = my_nodes(world, me, 2);
        let my_track = world
            .tracks()
            .filter(|(_, t)| t.owner == me)
            .map(|(id, _)| id)
            .last();
        if stage == 0 && nodes.len() == 2 {
            let (a, b) = (nodes[0], nodes[1]);
            net.client.submit(Command::BuildTrack { a, b });
            net.client.submit(Command::BuildStation { node: a });
            net.client.submit(Command::BuildStation { node: b });
            stage = 1;
        } else if let (1, Some(track)) = (stage, my_track) {
            net.client.submit(Command::SpawnTrain { track });
            net.client.chat("choo choo");
            stage = 2;
        }
        if tick >= start + args.ticks || !net.is_connected() {
            break;
        }
    }
    println!("done at tick {}", net.client.world().unwrap().tick());
    net.close().await;
}
