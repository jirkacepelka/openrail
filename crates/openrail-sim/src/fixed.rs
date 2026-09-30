//! Fixed-point numbers. The simulation never touches floats, so every
//! machine computes bit-identical results.

use core::fmt;
use core::ops::{Add, AddAssign, Div, Mul, Neg, Sub, SubAssign};
use serde::{Deserialize, Serialize};

/// Signed Q47.16 fixed-point number backed by an `i64`.
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Fixed(i64);

impl Fixed {
    pub const FRAC_BITS: u32 = 16;
    pub const ONE: Fixed = Fixed(1 << Self::FRAC_BITS);
    pub const ZERO: Fixed = Fixed(0);

    pub const fn from_bits(bits: i64) -> Self {
        Fixed(bits)
    }

    pub const fn to_bits(self) -> i64 {
        self.0
    }

    pub const fn from_int(n: i32) -> Self {
        Fixed((n as i64) << Self::FRAC_BITS)
    }

    /// `num / den` rounded toward zero. Panics if `den` is zero.
    pub const fn from_ratio(num: i32, den: i32) -> Self {
        Fixed(((num as i64) << Self::FRAC_BITS) / den as i64)
    }

    /// Integer part, rounded toward negative infinity.
    pub const fn floor_int(self) -> i64 {
        self.0 >> Self::FRAC_BITS
    }

    pub const fn abs(self) -> Self {
        Fixed(self.0.abs())
    }

    pub fn min(self, other: Self) -> Self {
        if self <= other {
            self
        } else {
            other
        }
    }

    pub fn max(self, other: Self) -> Self {
        if self >= other {
            self
        } else {
            other
        }
    }

    pub fn clamp(self, lo: Self, hi: Self) -> Self {
        self.max(lo).min(hi)
    }

    /// Integer square root on the raw bits; exact and platform independent.
    pub fn sqrt(self) -> Self {
        if self.0 <= 0 {
            return Fixed::ZERO;
        }
        let v = (self.0 as u128) << Self::FRAC_BITS;
        let mut x = 1u128 << ((128 - v.leading_zeros()).div_ceil(2));
        loop {
            let y = (x + v / x) / 2;
            if y >= x {
                return Fixed(x as i64);
            }
            x = y;
        }
    }

    /// Lossy conversion for rendering only. Never feed the result back
    /// into the simulation.
    pub fn to_f64_lossy(self) -> f64 {
        self.0 as f64 / (1u64 << Self::FRAC_BITS) as f64
    }
}

impl Add for Fixed {
    type Output = Fixed;
    fn add(self, rhs: Fixed) -> Fixed {
        Fixed(self.0 + rhs.0)
    }
}

impl AddAssign for Fixed {
    fn add_assign(&mut self, rhs: Fixed) {
        self.0 += rhs.0;
    }
}

impl Sub for Fixed {
    type Output = Fixed;
    fn sub(self, rhs: Fixed) -> Fixed {
        Fixed(self.0 - rhs.0)
    }
}

impl SubAssign for Fixed {
    fn sub_assign(&mut self, rhs: Fixed) {
        self.0 -= rhs.0;
    }
}

impl Neg for Fixed {
    type Output = Fixed;
    fn neg(self) -> Fixed {
        Fixed(-self.0)
    }
}

impl Mul for Fixed {
    type Output = Fixed;
    fn mul(self, rhs: Fixed) -> Fixed {
        Fixed(((self.0 as i128 * rhs.0 as i128) >> Self::FRAC_BITS) as i64)
    }
}

impl Div for Fixed {
    type Output = Fixed;
    fn div(self, rhs: Fixed) -> Fixed {
        Fixed((((self.0 as i128) << Self::FRAC_BITS) / rhs.0 as i128) as i64)
    }
}

impl fmt::Debug for Fixed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.4}", self.to_f64_lossy())
    }
}

impl fmt::Display for Fixed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic() {
        let a = Fixed::from_int(3);
        let b = Fixed::from_ratio(1, 2);
        assert_eq!(a + b, Fixed::from_ratio(7, 2));
        assert_eq!(a - b, Fixed::from_ratio(5, 2));
        assert_eq!(a * b, Fixed::from_ratio(3, 2));
        assert_eq!(a / b, Fixed::from_int(6));
        assert_eq!((-a).floor_int(), -3);
    }

    #[test]
    fn sqrt_is_exact_for_squares() {
        assert_eq!(Fixed::from_int(9).sqrt(), Fixed::from_int(3));
        assert_eq!(Fixed::from_int(144).sqrt(), Fixed::from_int(12));
        assert_eq!(Fixed::from_ratio(1, 4).sqrt(), Fixed::from_ratio(1, 2));
        assert_eq!(Fixed::ZERO.sqrt(), Fixed::ZERO);
    }
}
