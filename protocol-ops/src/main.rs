use crate::commands::{
    chain::ChainCommands, ctm::CtmCommands, dev::DevCommands, ecosystem::EcosystemCommands,
    hub::HubCommands,
};
use crate::common::{
    config::{init_global_config, GlobalConfig},
    error::log_error,
    logger,
};
use clap::{Parser, Subcommand};

mod common;
mod config;
mod types;

pub mod abi;
pub mod abi_contracts;
mod commands;

#[derive(Parser, Debug)]
#[command(name = "protocol-ops", about)]
struct ProtocolOps {
    #[command(subcommand)]
    command: ProtocolOpsSubcommands,
    #[clap(flatten)]
    global: ProtocolOpsGlobalArgs,
}

#[derive(Subcommand, Debug)]
pub enum ProtocolOpsSubcommands {
    /// Ecosystem related commands
    #[command(subcommand, alias = "eco")]
    Ecosystem(Box<EcosystemCommands>),
    /// Chain related commands
    #[command(subcommand)]
    Chain(Box<ChainCommands>),
    /// Bridgehub related commands
    #[command(subcommand)]
    Hub(Box<HubCommands>),
    /// Chain Type Manager related commands
    #[command(subcommand)]
    Ctm(Box<CtmCommands>),
    /// Developer utilities
    #[command(subcommand)]
    Dev(Box<DevCommands>),
}

#[derive(Parser, Debug)]
#[clap(next_help_heading = "Global options")]
struct ProtocolOpsGlobalArgs {
    /// Verbose mode
    #[clap(short, long, global = true)]
    verbose: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    human_panic::setup_panic!();
    let cli_args = ProtocolOps::parse();
    match run_subcommand(cli_args).await {
        Ok(_) => {}
        Err(error) => {
            log_error(error);
            std::process::exit(1);
        }
    }
    Ok(())
}

async fn run_subcommand(cli_args: ProtocolOps) -> anyhow::Result<()> {
    logger::init_theme();

    logger::new_empty_line();
    logger::intro();

    init_global_config_inner(&cli_args.global)?;

    match cli_args.command {
        ProtocolOpsSubcommands::Ecosystem(args) => commands::ecosystem::run(*args).await?,
        ProtocolOpsSubcommands::Chain(args) => commands::chain::run(*args).await?,
        ProtocolOpsSubcommands::Hub(args) => commands::hub::run(*args).await?,
        ProtocolOpsSubcommands::Ctm(args) => commands::ctm::run(*args).await?,
        ProtocolOpsSubcommands::Dev(args) => commands::dev::run(*args).await?,
    }
    Ok(())
}

fn init_global_config_inner(cli_args: &ProtocolOpsGlobalArgs) -> anyhow::Result<()> {
    init_global_config(GlobalConfig {
        verbose: cli_args.verbose,
    });
    Ok(())
}
