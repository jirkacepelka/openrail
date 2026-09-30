//! Terrain: the ground height as a pure function of the world seed and a
//! position. Nothing here is stored in [`crate::World`]; every machine that
//! knows the seed computes the same heights bit for bit (integer math
//! only), so the client, the server and every remote view agree.
//!
//! The landscape is made of layered gradient noise:
//! - broad plains whose level drifts slowly over tens of kilometres,
//! - gentle rolling hills everywhere,
//! - hilly regions (about a third of the land) with ridges up to ~200 m,
//! - a few shallow lakes in the plains,
//! - one meandering river crossing the map through a wide valley.
//!
//! Water is everything below [`WATER_LEVEL`]. The simulation does not use
//! heights yet (track length stays 2D).

use crate::Fixed;

/// Height of the water surface of rivers and lakes, in metres.
pub const WATER_LEVEL: Fixed = Fixed::from_int(12);
/// No point of the terrain is lower than this.
pub const MIN_HEIGHT: Fixed = Fixed::from_int(0);
/// No point of the terrain is higher than this.
pub const MAX_HEIGHT: Fixed = Fixed::from_int(280);

/// Height and wetness of one point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerrainSample {
    /// Ground height in metres (below [`WATER_LEVEL`] means under water).
    pub height: Fixed,
    /// 0 (dry) to 1 (river, lake shore): how wet the ground is, for
    /// shading and vegetation.
    pub wetness: Fixed,
}

const ONE: i64 = 1 << Fixed::FRAC_BITS;
const DIAG: i64 = 46341; // 0.7071 in Q16

/// Gradient directions: the axes and the diagonals, unit length.
const GRADS: [(i64, i64); 8] = [
    (ONE, 0),
    (-ONE, 0),
    (0, ONE),
    (0, -ONE),
    (DIAG, DIAG),
    (-DIAG, DIAG),
    (DIAG, -DIAG),
    (-DIAG, -DIAG),
];

/// (cos, sin) of k * 22.5 degrees for k = 0..16, in Q16.
const DIRS: [(i64, i64); 16] = [
    (65536, 0),
    (60547, 25080),
    (46341, 46341),
    (25080, 60547),
    (0, 65536),
    (-25080, 60547),
    (-46341, 46341),
    (-60547, 25080),
    (-65536, 0),
    (-60547, -25080),
    (-46341, -46341),
    (-25080, -60547),
    (0, -65536),
    (25080, -60547),
    (46341, -46341),
    (60547, -25080),
];

// Noise layers, told apart by their salt.
const SALT_PLAINS: u64 = 1;
const SALT_HILLY: u64 = 2;
const SALT_RIDGES: u64 = 3;
const SALT_HILLS: u64 = 4;
const SALT_ROLLING: u64 = 5;
const SALT_LAKES: u64 = 6;
const SALT_RIVER: u64 = 7;
const SALT_MOISTURE: u64 = 8;
const SALT_RIVER_LAYOUT: u64 = 9;

/// Half width of the river's water, in metres.
const RIVER_HALF_WIDTH: i64 = 45;
/// Distance from the river over which its valley rises to the land, in metres.
const RIVER_VALLEY: i64 = 1700;

fn m(metres: i64) -> i64 {
    metres * ONE
}

fn mul(a: i64, b: i64) -> i64 {
    (a * b) >> Fixed::FRAC_BITS
}

fn hash(seed: u64, salt: u64, ix: i64, iy: i64) -> u64 {
    let mut z = seed ^ salt.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z ^= (ix as u64).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = z.rotate_left(29);
    z ^= (iy as u64).wrapping_mul(0x94D0_49BB_1331_11EB);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Quintic fade 6t^5 - 15t^4 + 10t^3 for t in [0, 1], so the surface has
/// continuous slope and curvature (smooth normals).
fn fade(t: i64) -> i64 {
    let t3 = mul(mul(t, t), t);
    let inner = mul(t, 6 * t - 15 * ONE) + 10 * ONE;
    mul(t3, inner)
}

fn lerp(a: i64, b: i64, t: i64) -> i64 {
    a + mul(b - a, t)
}

fn smoothstep(e0: i64, e1: i64, x: i64) -> i64 {
    let t = (((x - e0) << Fixed::FRAC_BITS) / (e1 - e0)).clamp(0, ONE);
    mul(mul(t, t), 3 * ONE - 2 * t)
}

/// Gradient noise with a lattice of `cell` metres at (x, y) (Q16 metres).
/// Returns roughly -1..1 in Q16.
fn perlin(seed: u64, salt: u64, x: i64, y: i64, cell: i64) -> i64 {
    let span = cell << Fixed::FRAC_BITS;
    let (ix, iy) = (x.div_euclid(span), y.div_euclid(span));
    let fx = x.rem_euclid(span) / cell;
    let fy = y.rem_euclid(span) / cell;
    let corner = |dx: i64, dy: i64| {
        let (gx, gy) = GRADS[(hash(seed, salt, ix + dx, iy + dy) >> 61) as usize];
        mul(gx, fx - dx * ONE) + mul(gy, fy - dy * ONE)
    };
    let (u, v) = (fade(fx), fade(fy));
    let a = lerp(corner(0, 0), corner(1, 0), u);
    let b = lerp(corner(0, 1), corner(1, 1), u);
    // 2D gradient noise peaks at sqrt(1/2); scale it to about -1..1.
    mul(lerp(a, b, v), 92682)
}

/// Fractal sum of `octaves` noise layers starting at `cell` metres, each
/// half the size and half the strength of the previous one. About -1..1.
fn fbm(seed: u64, salt: u64, x: i64, y: i64, cell: i64, octaves: u32) -> i64 {
    let (mut sum, mut amp, mut total, mut cell) = (0, ONE, 0, cell);
    for o in 0..octaves {
        sum += mul(perlin(seed, salt * 16 + u64::from(o), x, y, cell), amp);
        total += amp;
        amp /= 2;
        cell = (cell / 2).max(1);
    }
    (sum << Fixed::FRAC_BITS) / total
}

/// Where the river runs: a direction and an offset from the map centre,
/// both from the seed.
fn river_layout(seed: u64) -> ((i64, i64), i64) {
    let h = hash(seed, SALT_RIVER_LAYOUT, 0, 0);
    let dir = DIRS[(h & 15) as usize];
    // -2500..2500 m across the river direction.
    let offset = m(((h >> 8) % 5001) as i64 - 2500);
    (dir, offset)
}

/// Distance in Q16 metres from (x, y) to the river's centre line.
fn river_distance(seed: u64, x: i64, y: i64) -> i64 {
    let ((c, s), offset) = river_layout(seed);
    let along = mul(x, c) + mul(y, s);
    let across = mul(-x, s) + mul(y, c);
    let meander = 4200 * fbm(seed, SALT_RIVER, along, 0, 9600, 2)
        + 700 * fbm(seed, SALT_RIVER, along, m(50_000), 2400, 2);
    (across - offset - meander).abs()
}

/// Height of the land before the river is cut into it, in Q16 metres.
fn land(seed: u64, x: i64, y: i64) -> i64 {
    let plains = fbm(seed, SALT_PLAINS, x, y, 12_800, 3);
    let hilly = smoothstep(-ONE / 20, ONE * 2 / 5, fbm(seed, SALT_HILLY, x, y, 9600, 2));
    let rolling = 10 * fbm(seed, SALT_ROLLING, x, y, 800, 3);
    let mut h = m(42) + 38 * plains + rolling;
    if hilly > 0 {
        // Rounded massifs with a few ridges on top.
        let ridge = ONE - fbm(seed, SALT_RIDGES, x, y, 4800, 2).abs();
        let ridge = mul(mul(ridge, ridge), ridge);
        let mass = fbm(seed, SALT_HILLS, x, y, 3200, 3) + ONE;
        h += mul(hilly, 110 * ridge + 55 * mass);
    }
    if hilly < ONE {
        // Shallow lakes, only in the plains.
        let lake = smoothstep(
            ONE * 3 / 10,
            ONE * 6 / 10,
            fbm(seed, SALT_LAKES, x, y, 4000, 2),
        );
        h -= mul(mul(lake, ONE - hilly), m(45));
    }
    h
}

fn sample_bits(seed: u64, x: i64, y: i64, with_wetness: bool) -> (i64, i64) {
    let water = WATER_LEVEL.to_bits();
    let bank = water + m(2);
    let d = river_distance(seed, x, y);
    // The river bed: 4 m under water in the middle, 2 m over it at the bank.
    let bed = water - m(4) + mul(m(6), smoothstep(0, m(RIVER_HALF_WIDTH), d));
    let valley = smoothstep(m(RIVER_HALF_WIDTH) / 2, m(RIVER_VALLEY), d);
    let h = if valley == 0 {
        bed
    } else {
        lerp(bed, land(seed, x, y).max(bank), valley)
    };
    let h = h.clamp(MIN_HEIGHT.to_bits(), MAX_HEIGHT.to_bits());
    if !with_wetness {
        return (h, 0);
    }
    let near_river = ONE - smoothstep(0, m(900), d);
    let low = ONE - smoothstep(water, water + m(8), h);
    let moisture = 3 * fbm(seed, SALT_MOISTURE, x, y, 2400, 2) / 10;
    let wet = (near_river.max(low) + moisture).clamp(0, ONE);
    (h, wet)
}

/// Ground height in metres at (x, y) metres for a world made from `seed`.
pub fn height(seed: u64, x: Fixed, y: Fixed) -> Fixed {
    Fixed::from_bits(sample_bits(seed, x.to_bits(), y.to_bits(), false).0)
}

/// Height and wetness at (x, y) metres for a world made from `seed`.
pub fn sample(seed: u64, x: Fixed, y: Fixed) -> TerrainSample {
    let (h, w) = sample_bits(seed, x.to_bits(), y.to_bits(), true);
    TerrainSample {
        height: Fixed::from_bits(h),
        wetness: Fixed::from_bits(w),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(seed: u64, x: i32, y: i32) -> Fixed {
        height(seed, Fixed::from_int(x), Fixed::from_int(y))
    }

    /// FNV-1a over a grid of heights, so any change to the terrain (or a
    /// platform computing it differently) shows up.
    fn grid_hash(seed: u64) -> u64 {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for iy in -20..=20 {
            for ix in -20..=20 {
                let v = h(seed, ix * 997, iy * 1009).to_bits();
                for b in v.to_le_bytes() {
                    hash ^= u64::from(b);
                    hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
                }
            }
        }
        hash
    }

    #[test]
    fn heights_are_a_pure_function_of_seed_and_position() {
        assert_eq!(grid_hash(42), grid_hash(42));
        assert_ne!(grid_hash(42), grid_hash(43));
        assert_eq!(
            height(7, Fixed::ZERO, Fixed::ZERO),
            height(7, Fixed::ZERO, Fixed::ZERO)
        );
    }

    /// Golden value: a change to the terrain must be on purpose.
    #[test]
    fn terrain_golden_hash() {
        assert_eq!(grid_hash(1), TERRAIN_GOLDEN);
    }

    const TERRAIN_GOLDEN: u64 = 0xb0825359a1cee37f;

    #[test]
    fn heights_stay_in_range_and_are_continuous() {
        for seed in [0u64, 1, 99] {
            for iy in -40..40 {
                let mut prev = h(seed, -20_000, iy * 500);
                for ix in -20_000..-19_000 {
                    let v = h(seed, ix, iy * 500);
                    assert!(v >= MIN_HEIGHT && v <= MAX_HEIGHT);
                    // 1 m apart: never a cliff.
                    assert!((v - prev).abs() < Fixed::from_int(2), "{seed} {ix} {iy}");
                    prev = v;
                }
            }
        }
    }

    #[test]
    fn map_has_hills_valleys_and_water() {
        for seed in [1u64, 2, 3] {
            let (mut lo, mut hi, mut wet) = (MAX_HEIGHT, MIN_HEIGHT, 0);
            let mut n = 0;
            for iy in -40..=40 {
                for ix in -40..=40 {
                    let v = h(seed, ix * 250, iy * 250);
                    lo = lo.min(v);
                    hi = hi.max(v);
                    n += 1;
                    if v < WATER_LEVEL {
                        wet += 1;
                    }
                }
            }
            assert!(lo < WATER_LEVEL, "seed {seed}: no water");
            assert!(hi > Fixed::from_int(80), "seed {seed}: no hills ({hi})");
            assert!(wet * 4 < n, "seed {seed}: mostly water");
        }
    }

    #[test]
    fn the_river_is_wet_and_under_water() {
        for seed in [5u64, 6, 7] {
            // The river crosses one of the two axes within the map.
            let best = (-20_000i32..20_000)
                .step_by(5)
                .flat_map(|t| [(t, 0), (0, t)])
                .min_by_key(|&(x, y)| river_distance(seed, m(i64::from(x)), m(i64::from(y))))
                .unwrap();
            let s = sample(seed, Fixed::from_int(best.0), Fixed::from_int(best.1));
            assert!(s.height < WATER_LEVEL, "seed {seed}: river above water");
            assert!(
                s.wetness > Fixed::from_ratio(9, 10),
                "seed {seed}: dry river"
            );
            let far = sample(
                seed,
                Fixed::from_int(best.0 + 3000),
                Fixed::from_int(best.1 + 3000),
            );
            assert!(far.wetness >= Fixed::ZERO && far.wetness <= Fixed::ONE);
        }
    }

    /// Prints the height distribution; run with --ignored --nocapture when
    /// tuning the landscape.
    #[test]
    #[ignore]
    fn print_stats() {
        for seed in [1u64, 2, 3, 4] {
            let mut buckets = [0u32; 15];
            for iy in -80..=80 {
                for ix in -80..=80 {
                    let v = h(seed, ix * 250, iy * 250).floor_int();
                    buckets[(v / 20).clamp(0, 14) as usize] += 1;
                }
            }
            println!("seed {seed}: {buckets:?}");
        }
    }
}
