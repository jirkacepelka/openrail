//! Economy state: companies and their money, towns, waiting passengers
//! and what each train carries. The rules that move this state each tick
//! live in `world::econ`, next to the rest of the world logic.
//!
//! Units:
//! - Money is an `i64` count of whole currency units (no cents). A
//!   balance may go negative through running costs; while it is, every
//!   command that costs money is rejected.
//! - Distances are metres (`Fixed`). A fare is paid pro rata per whole
//!   metre of straight-line distance between the boarding and alighting
//!   station: `count * metres * fare_per_km / 1000`, rounded down.
//! - Populations and passenger counts are plain `u32`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::command::PlayerId;
use crate::world::{NodeId, TrainId, Vec2};
use crate::{Fixed, SimRng};

/// Whole currency units.
pub type Money = i64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct TownId(pub u32);

/// Tunable numbers of the economy. Stored in the world (and therefore in
/// saves and the state hash) so every machine plays by the same rules.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EconomyRules {
    /// Balance a company starts with on its player's first command.
    pub starting_money: Money,
    /// Track cost per started metre of length.
    pub track_cost_per_metre: Money,
    /// Cost of turning a node into a station.
    pub station_cost: Money,
    /// Purchase price of a train.
    pub train_cost: Money,
    /// Share of `train_cost` paid back when a train is removed, in percent.
    pub train_refund_percent: Money,
    /// Charged to the owner for every train at the start of each day.
    pub train_running_cost_per_day: Money,
    /// Passengers one train carries.
    pub train_capacity: u32,
    /// Fare per passenger per kilometre of straight-line distance between
    /// the boarding and the alighting station.
    pub fare_per_km: Money,
    /// A station within this distance of a town centre serves the town.
    pub catchment_radius: Fixed,
    /// Each in-game hour a served station gets `population / divisor`
    /// new passengers on average (the remainder is rounded randomly).
    /// The default of 2400 means `population / 100` passengers a day.
    pub passenger_divisor: u32,
    /// A station holds at most this many waiting passengers; the rest
    /// give up, which counts against the town's service share.
    pub station_waiting_cap: u32,
    /// Share of a town's passengers that must be delivered in a month
    /// for the town to grow, in per mille.
    pub growth_threshold_permille: u32,
    /// Monthly growth at 100 % service is `population / divisor`.
    pub growth_divisor: u32,
    /// Towns stop growing at this size.
    pub max_town_population: u32,
}

impl Default for EconomyRules {
    fn default() -> Self {
        EconomyRules {
            starting_money: 2_000_000,
            track_cost_per_metre: 50,
            station_cost: 25_000,
            train_cost: 100_000,
            train_refund_percent: 50,
            train_running_cost_per_day: 200,
            train_capacity: 100,
            fare_per_km: 20,
            catchment_radius: Fixed::from_int(1000),
            passenger_divisor: 2400,
            station_waiting_cap: 1000,
            growth_threshold_permille: 250,
            growth_divisor: 50,
            max_town_population: 1_000_000,
        }
    }
}

/// A player's company.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Company {
    pub balance: Money,
    pub revenue_this_month: Money,
    pub expenses_this_month: Money,
    pub revenue_last_month: Money,
    pub expenses_last_month: Money,
}

impl Company {
    pub fn new(balance: Money) -> Self {
        Company {
            balance,
            revenue_this_month: 0,
            expenses_this_month: 0,
            revenue_last_month: 0,
            expenses_last_month: 0,
        }
    }
}

/// A town. Towns belong to nobody; they grow when their stations are
/// served well.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Town {
    pub pos: Vec2,
    pub name_seed: u32,
    pub population: u32,
    /// Passengers created at the town's stations this month.
    pub generated_this_month: u32,
    /// Passengers from the town's stations delivered this month.
    pub delivered_this_month: u32,
    pub generated_last_month: u32,
    pub delivered_last_month: u32,
}

impl Town {
    pub fn name(&self) -> String {
        town_name(self.name_seed)
    }

    /// Share of last month's passengers that were delivered, per mille.
    pub fn service_permille_last_month(&self) -> u32 {
        service_permille(self.generated_last_month, self.delivered_last_month)
    }
}

pub(crate) fn service_permille(generated: u32, delivered: u32) -> u32 {
    if generated == 0 {
        return 0;
    }
    ((delivered as u64 * 1000 / generated as u64).min(1000)) as u32
}

/// What a train carries and has earned.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrainCargo {
    /// Passengers on board keyed by (destination, origin) station.
    pub passengers: BTreeMap<(NodeId, NodeId), u32>,
    /// Revenue earned at the most recent stop.
    pub last_revenue: Money,
    /// Revenue earned since the train was bought.
    pub total_revenue: Money,
}

impl TrainCargo {
    pub fn load(&self) -> u32 {
        self.passengers.values().sum()
    }
}

/// All economy state of a world.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Economy {
    pub(crate) rules: EconomyRules,
    pub(crate) companies: BTreeMap<PlayerId, Company>,
    pub(crate) towns: BTreeMap<TownId, Town>,
    /// Waiting passengers per station, per destination station.
    pub(crate) waiting: BTreeMap<NodeId, BTreeMap<NodeId, u32>>,
    pub(crate) cargo: BTreeMap<TrainId, TrainCargo>,
}

impl Economy {
    pub fn new(rules: EconomyRules) -> Self {
        Economy {
            rules,
            ..Economy::default()
        }
    }

    pub(crate) fn balance(&self, player: PlayerId) -> Money {
        self.companies
            .get(&player)
            .map_or(self.rules.starting_money, |c| c.balance)
    }

    pub(crate) fn company_mut(&mut self, player: PlayerId) -> &mut Company {
        let start = self.rules.starting_money;
        self.companies
            .entry(player)
            .or_insert_with(|| Company::new(start))
    }

    /// Pays `amount` out of the player's balance. Callers check funds
    /// first where a shortfall must reject a command.
    pub(crate) fn spend(&mut self, player: PlayerId, amount: Money) {
        let c = self.company_mut(player);
        c.balance -= amount;
        c.expenses_this_month += amount;
    }

    pub(crate) fn earn(&mut self, player: PlayerId, amount: Money) {
        let c = self.company_mut(player);
        c.balance += amount;
        c.revenue_this_month += amount;
    }

    /// Money back that is not operating revenue (e.g. selling a train).
    pub(crate) fn refund(&mut self, player: PlayerId, amount: Money) {
        self.company_mut(player).balance += amount;
    }

    /// Fare for `count` passengers carried `metres` far.
    pub(crate) fn fare(&self, count: u32, metres: Fixed) -> Money {
        count as Money * metres.floor_int().max(0) * self.rules.fare_per_km / 1000
    }

    /// Cost of a track of the given length, per started metre.
    pub(crate) fn track_cost(&self, length: Fixed) -> Money {
        let metres = (length.to_bits() + Fixed::ONE.to_bits() - 1) >> Fixed::FRAC_BITS;
        metres * self.rules.track_cost_per_metre
    }
}

/// A pronounceable town name derived only from `seed`. Uses its own
/// generator so naming never disturbs the world's random stream.
pub fn town_name(seed: u32) -> String {
    const START: [&str; 16] = [
        "Bra", "No", "Vel", "Ka", "Ter", "Lin", "Mor", "Sta", "Den", "Ho", "Ri", "Zen", "Pol",
        "Dor", "Ven", "Mar",
    ];
    const MIDDLE: [&str; 12] = [
        "ra", "vo", "li", "ne", "ko", "da", "mi", "ta", "lo", "ze", "ri", "sa",
    ];
    const END: [&str; 12] = [
        "ov", "ice", "any", "in", "ec", "ton", "burg", "field", "ava", "ek", "by", "dale",
    ];
    let mut rng = SimRng::new(0x703E_5EED ^ seed as u64);
    let mut name = String::from(START[rng.below(START.len() as u64) as usize]);
    if rng.below(2) == 0 {
        name.push_str(MIDDLE[rng.below(MIDDLE.len() as u64) as usize]);
    }
    name.push_str(END[rng.below(END.len() as u64) as usize]);
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_stable_and_varied() {
        assert_eq!(town_name(7), town_name(7));
        let names: std::collections::BTreeSet<String> = (0..50).map(town_name).collect();
        assert!(names.len() > 30, "only {} distinct names", names.len());
        assert!(names
            .iter()
            .all(|n| n.chars().next().unwrap().is_uppercase()));
    }

    #[test]
    fn money_flows_through_companies() {
        let mut e = Economy::new(EconomyRules::default());
        let p = PlayerId(3);
        assert_eq!(e.balance(p), 2_000_000);
        assert!(e.companies.is_empty(), "reading must not create a company");
        e.spend(p, 500);
        e.earn(p, 200);
        e.refund(p, 50);
        let c = &e.companies[&p];
        assert_eq!(c.balance, 2_000_000 - 500 + 200 + 50);
        assert_eq!(c.expenses_this_month, 500);
        assert_eq!(c.revenue_this_month, 200);
    }

    #[test]
    fn fares_and_track_costs() {
        let e = Economy::new(EconomyRules::default());
        // 100 passengers over 3 km at 20 per km.
        assert_eq!(e.fare(100, Fixed::from_int(3000)), 6000);
        assert_eq!(e.fare(1, Fixed::from_int(49)), 0);
        assert_eq!(e.fare(1, Fixed::from_int(50)), 1);
        assert_eq!(e.track_cost(Fixed::from_int(10)), 500);
        assert_eq!(e.track_cost(Fixed::from_ratio(21, 2)), 550); // 10.5 m -> 11 m
    }

    #[test]
    fn service_share() {
        assert_eq!(service_permille(0, 0), 0);
        assert_eq!(service_permille(200, 50), 250);
        assert_eq!(service_permille(10, 30), 1000);
    }
}
