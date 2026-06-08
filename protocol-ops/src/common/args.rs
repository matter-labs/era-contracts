use std::path::PathBuf;

use clap::Args;
use serde::{Deserialize, Serialize};

use crate::common::forge::ForgeScriptArgs;

/// RPC / `--out` / forge flags shared by most protocol_ops commands.
///
/// Every prepare-shape command runs against a forked anvil fork of
/// `--l1-rpc-url` and emits a directory of Safe Transaction Builder bundles
/// (plus a `manifest.json` with debug metadata) via `--out`. Bundles are
/// applied separately via `dev execute-safe --safe-file --private-key` (or
/// any Safe-bundle-aware executor); consumers that need to dispatch a
/// multi-bundle manifest iterate `bundles[]` themselves and pick the matching
/// signer per `bundles[].target`.
///
/// Intentionally does **not** include `--private-key` *or* `--sender`. Every
/// prepare-shape command auto-resolves its simulation caller from L1 state
/// using the domain-specific anchor the command already requires (bridgehub +
/// chain id → chain admin, bridgehub → governance owner, etc.) — so the
/// operator doesn't have to name the signer. Bootstrap commands declare their
/// own `--deployer-address`.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct SharedRunArgs {
    /// L1 RPC URL
    #[clap(
        long,
        default_value = "http://localhost:8545",
        help_heading = "Execution"
    )]
    pub l1_rpc_url: String,

    /// Output directory for Safe Transaction Builder bundles + manifest.json
    /// (containing per-command debug metadata). Each command writes one
    /// `.safe.json` file per consecutive same-signer group plus appends one
    /// metadata entry to `manifest.json`.
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}
