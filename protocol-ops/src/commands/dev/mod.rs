use clap::Subcommand;

use crate::commands::dev::{
    execute_safe::DevExecuteSafeArgs, manifest_to_simulator::DevManifestToSimulatorArgs,
    restore_default_account::RestoreDefaultAccountArgs,
};

pub mod execute_manifest;
pub mod execute_safe;
pub mod manifest_to_simulator;
pub mod restore_default_account;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). For multi-bundle manifests, use
    /// `zk-deployer execute-manifest` which matches each bundle to the correct
    /// signer automatically.
    ExecuteSafe(DevExecuteSafeArgs),
    /// Convert a Safe-bundle manifest.json into transaction-simulator JSON
    ManifestToSimulator(DevManifestToSimulatorArgs),
    /// Swap a freshly built `DefaultAccount` artifact's metadata word back to the reviewed one
    /// so it hashes to the env's pinned `default_aa_hash` (the build is not bit-reproducible).
    RestoreDefaultAccount(RestoreDefaultAccountArgs),
}

pub async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
        DevCommands::ManifestToSimulator(args) => manifest_to_simulator::run(args).await,
        DevCommands::RestoreDefaultAccount(args) => restore_default_account::run(args),
    }
}
