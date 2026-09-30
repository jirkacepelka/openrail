//! Seeded random numbers. All randomness in the simulation comes from
//! the world's own `SimRng`, so a seed plus a command log replays exactly.

use serde::{Deserialize, Serialize};

use crate::Fixed;

/// xoshiro256** seeded through SplitMix64.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SimRng {
    s: [u64; 4],
}

impl SimRng {
    pub fn new(seed: u64) -> Self {
        let mut sm = seed;
        let mut next = || {
            sm = sm.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = sm;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        };
        SimRng {
            s: [next(), next(), next(), next()],
        }
    }

    pub fn next_u64(&mut self) -> u64 {
        let result = self.s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        result
    }

    /// Uniform integer in `0..bound`. Panics if `bound` is zero.
    pub fn below(&mut self, bound: u64) -> u64 {
        ((self.next_u64() as u128 * bound as u128) >> 64) as u64
    }

    /// Uniform value in `[0, 1)`.
    pub fn unit(&mut self) -> Fixed {
        Fixed::from_bits((self.next_u64() >> (64 - Fixed::FRAC_BITS)) as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_sequence() {
        let mut a = SimRng::new(42);
        let mut b = SimRng::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn bounded_values_stay_in_range() {
        let mut r = SimRng::new(7);
        for _ in 0..1000 {
            assert!(r.below(10) < 10);
            let u = r.unit();
            assert!(u >= Fixed::ZERO && u < Fixed::ONE);
        }
    }
}
