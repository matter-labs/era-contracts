use clap::{Parser, Subcommand};
use protocol_ops::commands::{
    chain::ChainCommands, ctm::CtmCommands, dev::DevCommands, ecosystem::EcosystemCommands,
    hub::HubCommands,
};
use protocol_ops::common::{
    config::{init_global_config, GlobalConfig},
    error::log_error,
    logger,
};

#[derive(Parser, Debug)]
#[command(name = "protocol-ops", about)]
struct ProtocolOps {
    #[command(subcommand)]
    command: ProtocolOpsSubcommands,
    #[clap(flatten)]
    global: ProtocolOpsGlobalArgs,
}

#[derive(Subcommand, Debug)]
enum ProtocolOpsSubcommands {
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
    /// Output results as machine-readable JSON (suppresses progress output)
    #[clap(long, global = true)]
    json: bool,
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
    init_global_config(GlobalConfig {
        verbose: cli_args.global.verbose,
        json_output: cli_args.global.json,
    });

    if !cli_args.global.json {
        logger::init_theme();
        logger::new_empty_line();
        logger::intro();
    }

    match cli_args.command {
        ProtocolOpsSubcommands::Ecosystem(args) => {
            protocol_ops::commands::ecosystem::run(*args).await?
        }
        ProtocolOpsSubcommands::Chain(args) => protocol_ops::commands::chain::run(*args).await?,
        ProtocolOpsSubcommands::Hub(args) => protocol_ops::commands::hub::run(*args).await?,
        ProtocolOpsSubcommands::Ctm(args) => protocol_ops::commands::ctm::run(*args).await?,
        ProtocolOpsSubcommands::Dev(args) => protocol_ops::commands::dev::run(*args).await?,
    }
    Ok(())
}
