//! Replays: a seed plus a tick-stamped command log. Running the same
//! replay anywhere must produce the same `World::state_hash`.

use serde::{Deserialize, Serialize};

use crate::command::{Command, PlayerId};
use crate::World;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScheduledCommand {
    /// The command is applied before this tick is simulated.
    pub tick: u64,
    pub player: PlayerId,
    pub command: Command,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Replay {
    pub seed: u64,
    pub commands: Vec<ScheduledCommand>,
}

impl Replay {
    pub fn new(seed: u64) -> Self {
        Replay {
            seed,
            commands: Vec::new(),
        }
    }

    pub fn push(&mut self, tick: u64, player: PlayerId, command: Command) {
        self.commands.push(ScheduledCommand {
            tick,
            player,
            command,
        });
    }

    /// Simulates `ticks` ticks from a fresh world. Rejected commands are
    /// skipped, exactly as a server would drop them.
    pub fn run(&self, ticks: u64) -> World {
        let mut world = World::new(self.seed);
        self.run_on(&mut world, ticks);
        world
    }

    /// Continues `world` up to tick `until`, applying the commands due in
    /// that range. Commands must be sorted by tick.
    pub fn run_on(&self, world: &mut World, until: u64) {
        let start = world.tick();
        let mut pending = self
            .commands
            .iter()
            .skip_while(|c| c.tick < start)
            .peekable();
        while world.tick() < until {
            let now = world.tick();
            while let Some(c) = pending.next_if(|c| c.tick == now) {
                let _ = world.apply(c.player, &c.command);
            }
            world.step();
        }
    }
}
