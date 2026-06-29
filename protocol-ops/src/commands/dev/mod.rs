use clap::Subcommand;

use crate::commands::dev::execute_safe::DevExecuteSafeArgs;

pub mod execute_manifest;
pub mod execute_safe;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). For multi-bundle manifests, use
    /// `zk-deployer execute-manifest` which matches each bundle to the correct
    /// signer automatically.
    ExecuteSafe(DevExecuteSafeArgs),
}

pub async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
    }
}
