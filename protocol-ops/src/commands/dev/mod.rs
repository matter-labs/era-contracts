use clap::Subcommand;

use crate::commands::dev::{
    execute_safe::DevExecuteSafeArgs, execution_runbook::DevExecutionRunbookArgs,
    manifest_to_simulator::DevManifestToSimulatorArgs,
};

pub mod execute_manifest;
pub mod execute_safe;
pub mod execution_runbook;
pub mod manifest_to_simulator;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). For multi-bundle manifests, use
    /// `zk-deployer execute-manifest` which matches each bundle to the correct
    /// signer automatically.
    ExecuteSafe(DevExecuteSafeArgs),
    /// Convert a Safe-bundle manifest.json into transaction-simulator JSON
    ManifestToSimulator(DevManifestToSimulatorArgs),
    /// Render EXECUTE.md, the copy-into-MetaMask runbook, from an upgrade's transaction list
    ExecutionRunbook(DevExecutionRunbookArgs),
}

pub async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
        DevCommands::ManifestToSimulator(args) => manifest_to_simulator::run(args).await,
        DevCommands::ExecutionRunbook(args) => execution_runbook::run(args).await,
    }
}
