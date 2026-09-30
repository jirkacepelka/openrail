//! In-game calendar derived purely from the tick counter.
//!
//! One in-game day lasts `TICKS_PER_DAY` ticks: 600 ticks, i.e. 60 seconds
//! of real time at 1x speed (10 ticks per second). A day has 24 in-game
//! hours of 25 ticks each. The calendar starts on 1 January `START_YEAR`
//! and has no leap years, so every year is exactly 365 days long.

use core::fmt;

use serde::{Deserialize, Serialize};

use crate::TICKS_PER_SECOND;

/// 60 real seconds at 1x speed.
pub const TICKS_PER_DAY: u64 = 60 * TICKS_PER_SECOND as u64;
pub const HOURS_PER_DAY: u64 = 24;
pub const TICKS_PER_HOUR: u64 = TICKS_PER_DAY / HOURS_PER_DAY;
pub const DAYS_PER_YEAR: u64 = 365;
pub const START_YEAR: i32 = 1950;

const MONTH_DAYS: [u8; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/// A calendar date. `month` is 1..=12, `day` is 1..=31.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Date {
    pub year: i32,
    pub month: u8,
    pub day: u8,
}

impl Date {
    /// The date `days` days after 1 January `START_YEAR`.
    pub fn from_day_number(days: u64) -> Date {
        let year = START_YEAR + (days / DAYS_PER_YEAR) as i32;
        let mut rest = (days % DAYS_PER_YEAR) as u16;
        let mut month = 1u8;
        for len in MONTH_DAYS {
            if rest < len as u16 {
                break;
            }
            rest -= len as u16;
            month += 1;
        }
        Date {
            year,
            month,
            day: rest as u8 + 1,
        }
    }

    /// The date of the given simulation tick.
    pub fn from_tick(tick: u64) -> Date {
        Date::from_day_number(tick / TICKS_PER_DAY)
    }
}

impl fmt::Display for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u8, day: u8) -> Date {
        Date { year, month, day }
    }

    #[test]
    fn day_numbers_map_to_dates() {
        assert_eq!(Date::from_day_number(0), date(1950, 1, 1));
        assert_eq!(Date::from_day_number(30), date(1950, 1, 31));
        assert_eq!(Date::from_day_number(31), date(1950, 2, 1));
        assert_eq!(Date::from_day_number(58), date(1950, 2, 28));
        assert_eq!(Date::from_day_number(59), date(1950, 3, 1));
        assert_eq!(Date::from_day_number(300), date(1950, 10, 28));
        assert_eq!(Date::from_day_number(364), date(1950, 12, 31));
        assert_eq!(Date::from_day_number(365), date(1951, 1, 1));
        assert_eq!(Date::from_day_number(365 * 50 + 59), date(2000, 3, 1));
    }

    #[test]
    fn ticks_map_to_days() {
        assert_eq!(TICKS_PER_DAY, 600);
        assert_eq!(TICKS_PER_HOUR, 25);
        assert_eq!(Date::from_tick(TICKS_PER_DAY - 1), date(1950, 1, 1));
        assert_eq!(Date::from_tick(TICKS_PER_DAY), date(1950, 1, 2));
        assert_eq!(date(1950, 3, 7).to_string(), "1950-03-07");
    }

    #[test]
    fn every_day_of_a_year_is_valid_and_increasing() {
        let mut prev = Date::from_day_number(0);
        for d in 1..DAYS_PER_YEAR * 2 {
            let cur = Date::from_day_number(d);
            assert!(cur > prev);
            assert!((1..=12).contains(&cur.month));
            assert!(cur.day >= 1 && cur.day <= MONTH_DAYS[cur.month as usize - 1]);
            prev = cur;
        }
    }
}
