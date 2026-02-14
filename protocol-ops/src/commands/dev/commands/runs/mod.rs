use clap::{command, Parser, Subcommand};
use xshell::Shell;

pub mod inspect;
pub mod list;

#[derive(Subcommand, Debug)]
pub enum RunsSubcommands {
    #[clap(about = "List runs")]
    List(list::RunsListArgs),
    #[clap(about = "Inspect a run")]
    Inspect(inspect::RunsInspectArgs),
}

#[derive(Parser, Debug)]
#[command()]
pub struct RunsCommand {
    #[command(subcommand)]
    command: Option<RunsSubcommands>,
    #[clap(flatten)]
    args: list::RunsListArgs,
}

pub async fn run(shell: &Shell, args: RunsCommand) -> anyhow::Result<()> {
    // match args {
    //     RunsCommands::List(args) => list::run(args, shell).await,
    //     RunsCommands::Inspect(args) => inspect::run(args, shell).await,
    // }
    match args.command {
        Some(RunsSubcommands::List(args)) => list::run(args, shell).await,
        Some(RunsSubcommands::Inspect(args)) => inspect::run(args, shell).await,
        None => list::run(args.args, shell).await,
    }
}
