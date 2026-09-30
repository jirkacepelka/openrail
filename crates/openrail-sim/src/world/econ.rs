//! Economy rules applied to the world: charging for construction, daily
//! running costs, passenger generation, loading and unloading at stops,
//! town growth, and read APIs for the UI.
//!
//! Timing (see `calendar`): every in-game hour (25 ticks) served stations
//! get new passengers; at the start of every day each train costs its
//! owner `train_running_cost_per_day`; on the 1st of every month towns
//! grow and monthly statistics roll over.

use std::collections::{BTreeMap, BTreeSet};

use super::{NodeId, Train, TrainId, World};
use crate::calendar::{Date, TICKS_PER_DAY, TICKS_PER_HOUR};
use crate::command::{CommandError, PlayerId};
use crate::economy::{service_permille, Company, EconomyRules, Money, Town, TownId, TrainCargo};
use crate::Fixed;

impl World {
    /// A fresh world playing by custom economy rules.
    pub fn with_rules(seed: u64, rules: EconomyRules) -> Self {
        let mut w = World::new(seed);
        w.economy = crate::economy::Economy::new(rules);
        w
    }

    pub fn rules(&self) -> &EconomyRules {
        &self.economy.rules
    }

    /// Today's in-game date.
    pub fn date(&self) -> Date {
        Date::from_tick(self.tick)
    }

    /// Days since the start of the game.
    pub fn day_number(&self) -> u64 {
        self.tick / TICKS_PER_DAY
    }

    /// A player's balance. Players who have not played yet report the
    /// starting money they will get.
    pub fn balance(&self, player: PlayerId) -> Money {
        self.economy.balance(player)
    }

    pub fn company(&self, player: PlayerId) -> Option<&Company> {
        self.economy.companies.get(&player)
    }

    pub fn companies(&self) -> impl Iterator<Item = (PlayerId, &Company)> {
        self.economy.companies.iter().map(|(p, c)| (*p, c))
    }

    pub fn towns(&self) -> impl Iterator<Item = (TownId, &Town)> {
        self.economy.towns.iter().map(|(id, t)| (*id, t))
    }

    pub fn town(&self, id: TownId) -> Option<&Town> {
        self.economy.towns.get(&id)
    }

    /// Passengers waiting at a station, per destination station.
    pub fn waiting_at(&self, station: NodeId) -> impl Iterator<Item = (NodeId, u32)> + '_ {
        self.economy
            .waiting
            .get(&station)
            .into_iter()
            .flatten()
            .map(|(d, n)| (*d, *n))
    }

    /// Total passengers waiting at a station.
    pub fn waiting_total(&self, station: NodeId) -> u32 {
        self.waiting_at(station).map(|(_, n)| n).sum()
    }

    /// What a train carries and has earned; `None` for trains that never
    /// carried anyone.
    pub fn train_cargo(&self, train: TrainId) -> Option<&TrainCargo> {
        self.economy.cargo.get(&train)
    }

    /// Passengers on board a train.
    pub fn train_load(&self, train: TrainId) -> u32 {
        self.train_cargo(train).map_or(0, TrainCargo::load)
    }

    /// The town a station serves: the nearest town centre within the
    /// catchment radius, ties going to the lower town id.
    pub fn station_town(&self, station: NodeId) -> Option<TownId> {
        let node = self.nodes.get(&station)?;
        if !node.station {
            return None;
        }
        let mut best: Option<(Fixed, TownId)> = None;
        for (&id, town) in &self.economy.towns {
            let d = town.pos.distance(node.pos);
            let closer = match best {
                None => true,
                Some((bd, _)) => d < bd,
            };
            if d <= self.economy.rules.catchment_radius && closer {
                best = Some((d, id));
            }
        }
        best.map(|(_, id)| id)
    }

    // --- command support -------------------------------------------------

    pub(super) fn ensure_funds(&self, player: PlayerId, cost: Money) -> Result<(), CommandError> {
        if self.economy.balance(player) < cost {
            return Err(CommandError::InsufficientFunds);
        }
        Ok(())
    }

    pub(super) fn found_town(
        &mut self,
        pos: super::Vec2,
        name_seed: u32,
        population: u32,
    ) -> Result<(), CommandError> {
        if population == 0 || population > self.economy.rules.max_town_population {
            return Err(CommandError::InvalidPopulation);
        }
        let id = TownId(self.alloc_id());
        self.economy.towns.insert(
            id,
            Town {
                pos,
                name_seed,
                population,
                generated_this_month: 0,
                delivered_this_month: 0,
                generated_last_month: 0,
                delivered_last_month: 0,
            },
        );
        Ok(())
    }

    /// Sells a train back: refund and lose its passengers.
    pub(super) fn sell_train(&mut self, id: TrainId, owner: PlayerId) {
        let r = &self.economy.rules;
        let refund = r.train_cost * r.train_refund_percent / 100;
        self.economy.refund(owner, refund);
        self.economy.cargo.remove(&id);
    }

    // --- per-stop and per-tick hooks -------------------------------------

    /// A train has stopped at `node`, which is `train.stops[train.next_stop]`.
    /// Unloads passengers destined here (paying the owner), then boards
    /// passengers bound for the train's other stops, nearest stop first.
    pub(super) fn exchange_passengers(&mut self, id: TrainId, train: &Train, node: NodeId) {
        let stops = &train.stops;
        let here = train.next_stop;

        // Unload. Passengers whose destination left the route get off
        // here too, without paying.
        let mut cargo = self.economy.cargo.remove(&id).unwrap_or_default();
        let leaving: Vec<(NodeId, NodeId)> = cargo
            .passengers
            .keys()
            .filter(|(dest, _)| *dest == node || !stops.contains(dest))
            .copied()
            .collect();
        let mut revenue: Money = 0;
        for key in leaving {
            let count = cargo.passengers.remove(&key).unwrap_or(0);
            let (dest, origin) = key;
            if dest != node {
                continue;
            }
            if let (Some(a), Some(b)) = (self.nodes.get(&origin), self.nodes.get(&dest)) {
                revenue += self.economy.fare(count, a.pos.distance(b.pos));
            }
            if let Some(town) = self.station_town(origin) {
                let t = self.economy.towns.get_mut(&town).expect("town exists");
                t.delivered_this_month = t.delivered_this_month.saturating_add(count);
            }
        }
        cargo.last_revenue = revenue;
        cargo.total_revenue += revenue;
        if revenue > 0 {
            self.economy.earn(train.owner, revenue);
        }

        // Board, in the order the train will reach its next stops.
        let mut free = self
            .economy
            .rules
            .train_capacity
            .saturating_sub(cargo.load());
        if let Some(waiting) = self.economy.waiting.get_mut(&node) {
            for k in 1..stops.len() {
                if free == 0 {
                    break;
                }
                let dest = stops[(here + k) % stops.len()];
                if dest == node {
                    continue;
                }
                let Some(n) = waiting.get_mut(&dest) else {
                    continue;
                };
                let take = (*n).min(free);
                *n -= take;
                free -= take;
                *cargo.passengers.entry((dest, node)).or_insert(0) += take;
                if *n == 0 {
                    waiting.remove(&dest);
                }
            }
            if waiting.is_empty() {
                self.economy.waiting.remove(&node);
            }
        }
        self.economy.cargo.insert(id, cargo);
    }

    /// Runs after `tick` has been advanced.
    pub(super) fn economy_step(&mut self) {
        if self.tick % TICKS_PER_HOUR == 0 {
            self.generate_passengers();
        }
        if self.tick % TICKS_PER_DAY == 0 {
            self.charge_running_costs();
            if self.date().day == 1 {
                self.end_month();
            }
        }
    }

    /// Every served station near a town gets new passengers for the
    /// stations that trains calling here also serve.
    fn generate_passengers(&mut self) {
        if self.economy.towns.is_empty() {
            return;
        }
        let mut destinations: BTreeMap<NodeId, BTreeSet<NodeId>> = BTreeMap::new();
        for train in self.trains.values() {
            for &from in &train.stops {
                for &to in &train.stops {
                    if to != from {
                        destinations.entry(from).or_default().insert(to);
                    }
                }
            }
        }
        let rules = &self.economy.rules;
        let (divisor, cap) = (rules.passenger_divisor.max(1), rules.station_waiting_cap);
        for (station, dests) in destinations {
            let Some(town) = self.station_town(station) else {
                continue;
            };
            let pop = self.economy.towns[&town].population;
            let mut count = pop / divisor;
            if (self.rng.below(divisor as u64) as u32) < pop % divisor {
                count += 1;
            }
            if count == 0 {
                continue;
            }
            let dests: Vec<NodeId> = dests.into_iter().collect();
            let t = self.economy.towns.get_mut(&town).expect("town exists");
            t.generated_this_month = t.generated_this_month.saturating_add(count);
            let waiting = self.economy.waiting.entry(station).or_default();
            let mut total: u32 = waiting.values().sum();
            for _ in 0..count {
                let dest = dests[self.rng.below(dests.len() as u64) as usize];
                if total < cap {
                    *waiting.entry(dest).or_insert(0) += 1;
                    total += 1;
                }
            }
            if waiting.is_empty() {
                self.economy.waiting.remove(&station);
            }
        }
    }

    fn charge_running_costs(&mut self) {
        let cost = self.economy.rules.train_running_cost_per_day;
        let owners: Vec<PlayerId> = self.trains.values().map(|t| t.owner).collect();
        for owner in owners {
            self.economy.spend(owner, cost);
        }
    }

    /// Month rollover: towns grow by how well they were served, and
    /// monthly figures move to "last month".
    fn end_month(&mut self) {
        let rules = self.economy.rules.clone();
        for town in self.economy.towns.values_mut() {
            let share = service_permille(town.generated_this_month, town.delivered_this_month);
            if share >= rules.growth_threshold_permille && share > 0 {
                let growth = (town.population as u64 * share as u64
                    / 1000
                    / rules.growth_divisor.max(1) as u64)
                    .max(1);
                town.population =
                    (town.population as u64 + growth).min(rules.max_town_population as u64) as u32;
            }
            town.generated_last_month = town.generated_this_month;
            town.delivered_last_month = town.delivered_this_month;
            town.generated_this_month = 0;
            town.delivered_this_month = 0;
        }
        for c in self.economy.companies.values_mut() {
            c.revenue_last_month = c.revenue_this_month;
            c.expenses_last_month = c.expenses_this_month;
            c.revenue_this_month = 0;
            c.expenses_this_month = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::calendar::{TICKS_PER_DAY, TICKS_PER_HOUR};
    use crate::command::{Command, CommandError, PlayerId};
    use crate::economy::{EconomyRules, TownId};
    use crate::world::{NodeId, TrackId, TrainId, Vec2, World};
    use crate::Fixed;

    const P: PlayerId = PlayerId(1);

    fn pos(x: i32, y: i32) -> Vec2 {
        Vec2::new(Fixed::from_int(x), Fixed::from_int(y))
    }

    fn cmd(w: &mut World, c: Command) {
        w.apply(P, &c)
            .unwrap_or_else(|e| panic!("{c:?} rejected: {e}"));
    }

    /// Two stations 2 km apart (nodes 1 and 2, track 3), each with a
    /// town, and one train (4) shuttling between them on a route.
    fn line(rules: EconomyRules) -> World {
        let mut w = World::with_rules(99, rules);
        cmd(&mut w, Command::BuildNode { pos: pos(0, 0) });
        cmd(&mut w, Command::BuildNode { pos: pos(2000, 0) });
        cmd(
            &mut w,
            Command::BuildTrack {
                a: NodeId(1),
                b: NodeId(2),
            },
        );
        cmd(&mut w, Command::BuildStation { node: NodeId(1) });
        cmd(&mut w, Command::BuildStation { node: NodeId(2) });
        cmd(&mut w, Command::SpawnTrain { track: TrackId(3) });
        cmd(
            &mut w,
            Command::SetRoute {
                train: TrainId(4),
                stops: vec![NodeId(2), NodeId(1)],
            },
        );
        cmd(
            &mut w,
            Command::FoundTown {
                pos: pos(-100, 50),
                name_seed: 1,
                population: 4800,
            },
        );
        cmd(
            &mut w,
            Command::FoundTown {
                pos: pos(2100, -50),
                name_seed: 2,
                population: 4800,
            },
        );
        w
    }

    fn run(w: &mut World, ticks: u64) {
        for _ in 0..ticks {
            w.step();
        }
    }

    #[test]
    fn construction_is_charged() {
        let rules = EconomyRules::default();
        let w = line(rules.clone());
        let spent = 2000 * rules.track_cost_per_metre + 2 * rules.station_cost + rules.train_cost;
        assert_eq!(w.balance(P), rules.starting_money - spent);
        assert_eq!(w.company(P).unwrap().expenses_this_month, spent);
    }

    #[test]
    fn unaffordable_commands_are_rejected_untouched() {
        let rules = EconomyRules {
            starting_money: 110_000,
            ..EconomyRules::default()
        };
        let mut w = World::with_rules(1, rules);
        cmd(&mut w, Command::BuildNode { pos: pos(0, 0) });
        cmd(&mut w, Command::BuildNode { pos: pos(1000, 0) });
        cmd(&mut w, Command::BuildNode { pos: pos(9000, 0) });
        // 1 km costs 50 000, leaving 60 000.
        cmd(
            &mut w,
            Command::BuildTrack {
                a: NodeId(1),
                b: NodeId(2),
            },
        );
        assert_eq!(w.balance(P), 60_000);
        let before = w.clone();
        let too_long = Command::BuildTrack {
            a: NodeId(2),
            b: NodeId(3),
        };
        assert_eq!(w.apply(P, &too_long), Err(CommandError::InsufficientFunds));
        let train = Command::SpawnTrain { track: TrackId(4) };
        assert_eq!(w.apply(P, &train), Err(CommandError::InsufficientFunds));
        assert_eq!(w, before);
        // A station still fits; building it twice costs once.
        cmd(&mut w, Command::BuildStation { node: NodeId(1) });
        cmd(&mut w, Command::BuildStation { node: NodeId(1) });
        assert_eq!(w.balance(P), 35_000);
    }

    #[test]
    fn a_new_player_gets_a_company_on_first_command() {
        let mut w = World::new(5);
        assert!(w.company(PlayerId(9)).is_none());
        assert_eq!(w.balance(PlayerId(9)), w.rules().starting_money);
        // A rejected command does not found a company.
        let bad = Command::BuildStation { node: NodeId(77) };
        assert!(w.apply(PlayerId(9), &bad).is_err());
        assert!(w.company(PlayerId(9)).is_none());
        w.apply(PlayerId(9), &Command::BuildNode { pos: pos(1, 1) })
            .unwrap();
        assert_eq!(
            w.company(PlayerId(9)).unwrap().balance,
            w.rules().starting_money
        );
    }

    #[test]
    fn selling_a_train_refunds_half() {
        let mut w = line(EconomyRules::default());
        let before = w.balance(P);
        cmd(&mut w, Command::RemoveTrain { train: TrainId(4) });
        assert_eq!(w.balance(P), before + 50_000);
    }

    #[test]
    fn running_costs_are_charged_daily() {
        let mut w = World::new(3);
        cmd(&mut w, Command::BuildNode { pos: pos(0, 0) });
        cmd(&mut w, Command::BuildNode { pos: pos(500, 0) });
        cmd(
            &mut w,
            Command::BuildTrack {
                a: NodeId(1),
                b: NodeId(2),
            },
        );
        cmd(&mut w, Command::SpawnTrain { track: TrackId(3) });
        let start = w.balance(P);
        run(&mut w, TICKS_PER_DAY - 1);
        assert_eq!(w.balance(P), start);
        run(&mut w, 1);
        assert_eq!(w.balance(P), start - 200);
        run(&mut w, 2 * TICKS_PER_DAY);
        assert_eq!(w.balance(P), start - 600);
    }

    #[test]
    fn found_town_validates_population() {
        let mut w = World::new(1);
        let c = |population| Command::FoundTown {
            pos: pos(0, 0),
            name_seed: 4,
            population,
        };
        assert_eq!(w.apply(P, &c(0)), Err(CommandError::InvalidPopulation));
        assert_eq!(
            w.apply(P, &c(2_000_000)),
            Err(CommandError::InvalidPopulation)
        );
        cmd(&mut w, c(1234));
        let (id, town) = w.towns().next().unwrap();
        assert_eq!(id, TownId(1));
        assert_eq!(town.population, 1234);
        assert!(!town.name().is_empty());
    }

    #[test]
    fn stations_serve_the_nearest_town_in_range() {
        let mut w = line(EconomyRules::default());
        assert_eq!(w.station_town(NodeId(1)), Some(TownId(5)));
        assert_eq!(w.station_town(NodeId(2)), Some(TownId(6)));
        assert_eq!(w.station_town(NodeId(3)), None); // a track, not a node
        cmd(&mut w, Command::BuildNode { pos: pos(1000, 0) });
        cmd(&mut w, Command::BuildStation { node: NodeId(7) });
        assert_eq!(w.station_town(NodeId(7)), None); // 1 km+ from both
    }

    #[test]
    fn passengers_appear_hourly_for_served_destinations() {
        let mut w = line(EconomyRules::default());
        assert_eq!(w.waiting_total(NodeId(1)), 0);
        run(&mut w, TICKS_PER_HOUR);
        // 4800 / 2400 = exactly 2 per hour at each station.
        assert_eq!(
            w.waiting_at(NodeId(1)).collect::<Vec<_>>(),
            [(NodeId(2), 2)]
        );
        assert_eq!(
            w.waiting_at(NodeId(2)).collect::<Vec<_>>(),
            [(NodeId(1), 2)]
        );
        assert_eq!(w.town(TownId(5)).unwrap().generated_this_month, 2);
    }

    #[test]
    fn waiting_passengers_are_capped() {
        // Trains that carry nobody let passengers pile up to the cap.
        let rules = EconomyRules {
            station_waiting_cap: 25,
            train_capacity: 0,
            ..EconomyRules::default()
        };
        let mut w = line(rules);
        run(&mut w, 10 * TICKS_PER_HOUR);
        assert_eq!(w.waiting_total(NodeId(1)), 20);
        run(&mut w, 3 * TICKS_PER_HOUR);
        assert_eq!(w.waiting_total(NodeId(1)), 25);
        assert_eq!(w.town(TownId(5)).unwrap().generated_this_month, 26);
    }

    #[test]
    fn unserved_stations_get_no_passengers() {
        let mut w = line(EconomyRules::default());
        cmd(&mut w, Command::RemoveTrain { train: TrainId(4) });
        run(&mut w, TICKS_PER_HOUR);
        assert_eq!(w.waiting_total(NodeId(1)), 0);
        assert_eq!(w.town(TownId(5)).unwrap().generated_this_month, 0);
    }

    #[test]
    fn trains_deliver_passengers_and_earn_fares() {
        let rules = EconomyRules::default();
        let mut w = line(rules.clone());
        let start = w.balance(P);
        let mut max_load = 0;
        let mut earned = 0;
        for _ in 0..(10 * TICKS_PER_DAY) {
            w.step();
            max_load = max_load.max(w.train_load(TrainId(4)));
            earned = w.train_cargo(TrainId(4)).map_or(0, |c| c.total_revenue);
        }
        assert!(max_load > 0, "nobody ever boarded");
        assert!(max_load <= rules.train_capacity);
        assert!(earned > 0, "no revenue");
        // Every fare is for exactly 2 km: 40 per passenger.
        assert_eq!(earned % 40, 0);
        let running = 10 * rules.train_running_cost_per_day;
        assert_eq!(w.balance(P), start + earned - running);
        let c = w.company(P).unwrap();
        assert_eq!(c.revenue_this_month, earned);
        let t = w.town(TownId(5)).unwrap();
        assert!(t.delivered_this_month > 0);
        assert!(t.delivered_this_month <= t.generated_this_month);
    }

    #[test]
    fn a_full_train_leaves_passengers_behind() {
        let rules = EconomyRules {
            train_capacity: 3,
            ..EconomyRules::default()
        };
        let mut w = line(rules);
        for _ in 0..(3 * TICKS_PER_DAY) {
            w.step();
            assert!(w.train_load(TrainId(4)) <= 3);
        }
        assert!(w.waiting_total(NodeId(1)) > 0 || w.waiting_total(NodeId(2)) > 0);
    }

    #[test]
    fn well_served_towns_grow_and_unserved_do_not() {
        let mut w = line(EconomyRules::default());
        cmd(
            &mut w,
            Command::FoundTown {
                pos: pos(50_000, 50_000),
                name_seed: 3,
                population: 4800,
            },
        );
        // Through 1 February: one month rollover.
        run(&mut w, 31 * TICKS_PER_DAY);
        assert_eq!(w.date().to_string(), "1950-02-01");
        let served = w.town(TownId(5)).unwrap();
        let lonely = w.town(TownId(7)).unwrap();
        assert_eq!(lonely.population, 4800);
        assert_eq!(lonely.generated_last_month, 0);
        assert!(served.generated_last_month > 0);
        assert!(
            served.service_permille_last_month() >= 250,
            "served only {} per mille",
            served.service_permille_last_month()
        );
        assert!(served.population > 4800);
        assert_eq!(served.generated_this_month, 0);
        let c = w.company(P).unwrap();
        assert!(c.revenue_last_month > 0);
        assert_eq!(c.revenue_this_month, 0);
    }

    #[test]
    fn economy_state_survives_save_and_load() {
        let mut w = line(EconomyRules::default());
        run(&mut w, 3 * TICKS_PER_DAY + 7);
        let mut loaded = World::load(&w.save()).unwrap();
        assert_eq!(loaded, w);
        run(&mut w, TICKS_PER_DAY);
        run(&mut loaded, TICKS_PER_DAY);
        assert_eq!(loaded.state_hash(), w.state_hash());
    }
}
