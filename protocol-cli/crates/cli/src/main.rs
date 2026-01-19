use crate::commands::{
    chain::ChainCommands, ctm::CtmCommands, dev::DevCommands, ecosystem::EcosystemCommands,
    hub::HubCommands,
};
use clap::{command, Parser, Subcommand};
use protocol_cli_common::{
    config::{init_global_config, GlobalConfig},
    error::log_error,
    init_prompt_theme, logger,
};
use xshell::Shell;

pub mod abi;
pub mod admin_functions;
mod commands;
mod utils;

#[derive(Parser, Debug)]
#[command(name = "protocol-cli", about)]
struct ProtocolCli {
    #[command(subcommand)]
    command: ProtocolCliSubcommands,
    #[clap(flatten)]
    global: ProtocolCliGlobalArgs,
}

#[derive(Subcommand, Debug)]
pub enum ProtocolCliSubcommands {
    /// Ecosystem related commands
    #[command(subcommand, alias = "eco")]
    Ecosystem(Box<EcosystemCommands>),
    /// Chain related commands
    #[command(subcommand)]
    Chain(Box<ChainCommands>),
    /// Hub related commands
    #[command(subcommand)]
    Hub(Box<HubCommands>),
    /// Chain Type Manager related commands
    #[command(subcommand)]
    Ctm(Box<CtmCommands>),
    /// Dev related commands
    #[command(subcommand)]
    Dev(Box<DevCommands>),
}

#[derive(Parser, Debug)]
#[clap(next_help_heading = "Global options")]
struct ProtocolCliGlobalArgs {
    /// Verbose mode
    #[clap(short, long, global = true)]
    verbose: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    human_panic::setup_panic!();
    let cli_args = ProtocolCli::parse();
    match run_subcommand(cli_args).await {
        Ok(_) => {}
        Err(error) => {
            log_error(error);
            std::process::exit(1);
        }
    }
    Ok(())
}

async fn run_subcommand(cli_args: ProtocolCli) -> anyhow::Result<()> {
    init_prompt_theme();

    logger::new_empty_line();
    logger::intro();

    init_global_config_inner(&cli_args.global)?;
    let shell = Shell::new().unwrap();

    match cli_args.command {
        ProtocolCliSubcommands::Ecosystem(args) => commands::ecosystem::run(&shell, *args).await?,
        ProtocolCliSubcommands::Chain(args) => commands::chain::run(&shell, *args).await?,
        ProtocolCliSubcommands::Hub(args) => commands::hub::run(&shell, *args).await?,
        ProtocolCliSubcommands::Ctm(args) => commands::ctm::run(&shell, *args).await?,
        ProtocolCliSubcommands::Dev(args) => commands::dev::run(&shell, *args).await?,
    }
    Ok(())
}

fn init_global_config_inner(cli_args: &ProtocolCliGlobalArgs) -> anyhow::Result<()> {
    init_global_config(GlobalConfig {
        verbose: cli_args.verbose,
    });
    Ok(())
}
