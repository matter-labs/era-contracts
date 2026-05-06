use clap::Subcommand;

use crate::commands::dev::execute_safe::DevExecuteSafeArgs;

pub(crate) mod execute_safe;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute a Gnosis Safe Transaction Builder JSON file (one bundle, one signer)
    ExecuteSafe(DevExecuteSafeArgs),
}

pub(crate) async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
    }
}
