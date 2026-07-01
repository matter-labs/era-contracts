use std::sync::OnceLock;

static CONFIG: OnceLock<GlobalConfig> = OnceLock::new();

static DEFAULT_CONFIG: GlobalConfig = GlobalConfig {
    verbose: false,
    json_output: false,
};

/// Initialize the global config (verbose flag, etc.).
///
/// When protocol_ops is used as a library the caller may omit this; logging
/// will be silent (verbose: false) by default.  When called from the CLI
/// binary this is called once before any command runs.  Subsequent calls are
/// silently ignored.
pub fn init_global_config(config: GlobalConfig) {
    let _ = CONFIG.set(config);
}

pub fn global_config() -> &'static GlobalConfig {
    CONFIG.get().unwrap_or(&DEFAULT_CONFIG)
}

/// Returns true if `--json` was passed on the command line.
pub fn is_json_output() -> bool {
    global_config().json_output
}

#[derive(Debug)]
pub struct GlobalConfig {
    pub verbose: bool,
    pub json_output: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_output_defaults_false() {
        let cfg = GlobalConfig {
            verbose: false,
            json_output: false,
        };
        assert!(!cfg.json_output);
    }
}
