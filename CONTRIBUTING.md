# Contributing to OpenRail

Thanks for helping out!

## Sign-off (DCO)

All commits must carry a Developer Certificate of Origin sign-off:
`git commit -s` adds `Signed-off-by: Your Name <you@example.com>`.

## Before opening a pull request

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --exclude openrail-gdext
```

## Determinism rule

`openrail-sim` must be bit-for-bit deterministic across platforms, because the
client and the server run the same code and compare state hashes. Inside
`openrail-sim` do NOT use:

- floating point (`f32` / `f64`); use `Fixed`,
- `HashMap` / `HashSet` (iteration order); use `BTreeMap` / `BTreeSet`,
- system time or other ambient input,
- anything whose order depends on threads.

Randomness must come from `SimRng`. Floats may only be converted at the
boundary (e.g. in `openrail-gdext`).

## Licensing

Code contributions are MIT; asset contributions are CC BY-SA 4.0.
