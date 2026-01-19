use clap::Subcommand;
use xshell::Shell;

use crate::commands::dev::commands::runs::RunsCommand;

pub(crate) mod commands;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum DevCommands {
    #[command(about = "Subcommands for managing runs")]
    Runs(RunsCommand),
}

pub(crate) async fn run(shell: &Shell, args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::Runs(args) => commands::runs::run(shell, args).await,
    }
}
