//! Server configuration, loaded from a TOML file.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Config {
    pub bind: String,
    pub seed: u64,
    pub save_path: String,
    pub autosave_ticks: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            bind: "0.0.0.0:7878".into(),
            seed: 0,
            save_path: "world.bin".into(),
            autosave_ticks: 3000,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_apply_for_empty_and_partial_config() {
        let c: Config = toml::from_str("").unwrap();
        assert_eq!(c, Config::default());
        assert_eq!(c.bind, "0.0.0.0:7878");
        assert_eq!(c.save_path, "world.bin");
        assert_eq!(c.autosave_ticks, 3000);

        let c: Config = toml::from_str("seed = 42").unwrap();
        assert_eq!(c.seed, 42);
        assert_eq!(c.bind, "0.0.0.0:7878");
    }
}
