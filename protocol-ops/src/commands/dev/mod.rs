use clap::Subcommand;

use crate::commands::dev::execute_manifest::DevExecuteManifestArgs;
use crate::commands::dev::execute_safe::DevExecuteSafeArgs;

pub mod execute_manifest;
pub mod execute_safe;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). For multi-bundle manifests, prefer
    /// `execute-manifest` which matches each bundle to the correct signer
    /// automatically.
    ExecuteSafe(DevExecuteSafeArgs),

    /// Apply every bundle in a `manifest.json` file, routing each to the
    /// correct signer automatically.
    ///
    /// `manifest.json` is produced by `bootstrap` / `apply` in their `--out`
    /// directory. Supply all potential signing keys via `--private-key`
    /// (repeatable) and/or `--wallets wallets.yaml`. The command derives
    /// Ethereum addresses from the supplied keys and matches each bundle's
    /// `target` field to the right key.
    ///
    /// On localhost Anvil, target addresses are funded automatically via
    /// `anvil_setBalance` before each bundle is applied. Pass
    /// `--fund-targets=false` when targeting a real chain.
    ExecuteManifest(DevExecuteManifestArgs),
}

pub async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
        DevCommands::ExecuteManifest(args) => execute_manifest::run(args).await,
    }
}
