use clap::Subcommand;

use crate::commands::dev::execute_safe::DevExecuteSafeArgs;

pub(crate) mod execute_safe;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute one Gnosis Safe Transaction Builder JSON file under one signer
    /// (`--safe-file` + `--private-key`). Multi-bundle manifests emitted by
    /// prepare-shape commands are dispatched by the caller — read
    /// `<dir>/manifest.json` and invoke this command once per bundle, picking
    /// the signer that matches each `bundles[].target`.
    ExecuteSafe(DevExecuteSafeArgs),
}

pub(crate) async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteSafe(args) => execute_safe::run(args).await,
    }
}
