use std::path::Path;

use clap::Subcommand;

use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};

pub(crate) mod convert;
pub(crate) mod migrate;

/// Gateway operations: converting a chain into a gateway or migrating a chain to use one.
#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum GatewayCommands {
    /// Convert a chain into a gateway (settlement layer)
    #[command(subcommand)]
    Convert(ConvertCommands),
    /// Migrate a chain to use a gateway as its settlement layer
    #[command(subcommand)]
    Migrate(MigrateCommands),
}

pub use convert::ConvertCommands;
pub use migrate::MigrateCommands;

pub(crate) async fn run(args: GatewayCommands) -> anyhow::Result<()> {
    match args {
        GatewayCommands::Convert(cmd) => convert::run(cmd).await,
        GatewayCommands::Migrate(cmd) => migrate::run(cmd).await,
    }
}

/// Build a forge script targeting `AdminFunctions.s.sol` with common arguments.
pub(super) fn build_admin_functions_script(
    contracts_path: &Path,
    runner: &ForgeRunner,
    forge_args: &crate::common::forge::ForgeScriptArgs,
    sig: &str,
    additional_args: Vec<String>,
) -> anyhow::Result<crate::common::forge::ForgeScript> {
    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: sig.to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend(additional_args);

    Ok(Forge::new(contracts_path).script(Path::new(script_path), script_args))
}
