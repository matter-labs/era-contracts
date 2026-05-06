mod cast_transactions;
mod runner;
mod script;
use std::path::{Path, PathBuf};

pub use cast_transactions::{split_into_bundles, SafeBundle};
pub use runner::ForgeRunner;
pub use script::{ForgeScript, ForgeScriptArg, ForgeScriptArgs};

/// Default gas limit for forge scripts that execute L1→L2 or governance transactions.
pub const DEFAULT_SCRIPT_GAS_LIMIT: u64 = 1_000_000_000_000;

/// Forge is a wrapper around the forge binary.
pub struct Forge {
    path: PathBuf,
}

impl Forge {
    /// Create a new Forge instance.
    pub fn new(path: &Path) -> Self {
        Forge {
            path: path.to_path_buf(),
        }
    }

    /// Create a new ForgeScript instance.
    ///
    /// The script path can be passed as a relative path to the base path
    /// or as an absolute path.
    pub fn script(&self, path: &Path, args: ForgeScriptArgs) -> ForgeScript {
        ForgeScript {
            base_path: self.path.clone(),
            script_path: path.to_path_buf(),
            args,
            envs: Vec::new(),
        }
    }
}
