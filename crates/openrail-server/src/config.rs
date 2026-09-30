//! Server configuration, loaded from a TOML file.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Config {
    /// HTTP admin API (TCP).
    pub bind: String,
    /// Game traffic (QUIC over UDP). May share the port number with `bind`
    /// since one is TCP and the other UDP.
    pub game_bind: String,
    pub seed: u64,
    pub save_path: String,
    pub autosave_ticks: u64,
    /// Players must send this in their Hello when set.
    pub password: Option<String>,
    pub max_players: usize,
    /// Sustained commands per second per player; bursts of up to
    /// `command_burst` are allowed.
    pub commands_per_second: u32,
    pub command_burst: u32,
    /// Extra ticks between receiving a command and executing it.
    pub input_delay_ticks: u64,
    /// Ticks between state hash comparisons with clients.
    pub hash_interval_ticks: u64,
    /// Self-signed certificate (DER) and key (PKCS#8 DER), created on first
    /// start. Keep them: clients pin the certificate's fingerprint.
    pub cert_path: String,
    pub key_path: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            bind: "0.0.0.0:7878".into(),
            game_bind: "0.0.0.0:7878".into(),
            seed: 0,
            save_path: "world.bin".into(),
            autosave_ticks: 3000,
            password: None,
            max_players: 16,
            commands_per_second: 20,
            command_burst: 40,
            input_delay_ticks: 0,
            hash_interval_ticks: 50,
            cert_path: "server-cert.der".into(),
            key_path: "server-key.der".into(),
        }
    }
}

impl Config {
    pub fn host_config(&self) -> openrail_net::HostConfig {
        openrail_net::HostConfig {
            password: self.password.clone().filter(|p| !p.is_empty()),
            max_players: self.max_players,
            input_delay: self.input_delay_ticks,
            hash_interval: self.hash_interval_ticks,
            commands_per_second: self.commands_per_second,
            command_burst: self.command_burst,
            ..openrail_net::HostConfig::default()
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
        assert_eq!(c.password, None);

        let c: Config = toml::from_str("seed = 42\npassword = \"pw\"").unwrap();
        assert_eq!(c.seed, 42);
        assert_eq!(c.bind, "0.0.0.0:7878");
        assert_eq!(c.host_config().password.as_deref(), Some("pw"));
    }

    #[test]
    fn empty_password_means_none() {
        let c: Config = toml::from_str("password = \"\"").unwrap();
        assert_eq!(c.host_config().password, None);
    }
}
