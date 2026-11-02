use std::sync::OnceLock;

static CONFIG: OnceLock<GlobalConfig> = OnceLock::new();

static DEFAULT_CONFIG: GlobalConfig = GlobalConfig {
    verbose: false,
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

#[derive(Debug)]
pub struct GlobalConfig {
    pub verbose: bool,
}

