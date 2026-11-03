use clap::Subcommand;

use crate::commands::dev::{
    execute_safe::DevExecuteSafeArgs, execution_runbook::DevExecutionRunbookArgs,
};

pub mod execute_safe;
pub mod execution_runbook;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). For multi-bundle manifests, use
    /// `ecosystem upgrade-broadcast`, which matches each bundle to the correct
    /// signer automatically.
    ExecuteSafe(DevExecuteSafeArgs),
    /// Render EXECUTE.md, the copy-into-MetaMask runbook, from an upgrade's transaction list
    ExecutionRunbook(DevExecutionRunbookArgs),
}

pub async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
        DevCommands::ExecutionRunbook(args) => execution_runbook::run(args).await,
    }
}
