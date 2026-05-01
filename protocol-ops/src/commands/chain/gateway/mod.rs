use std::path::Path;

use clap::Subcommand;

use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};

pub(crate) mod convert;
pub(crate) mod migrate_from;
pub(crate) mod migrate_to;

/// Gateway operations: converting a chain into a gateway or migrating a chain to/from one.
#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum GatewayCommands {
    /// Phase-level convert-to-gateway flow (runs all five stages on one fork).
    Convert(ConvertArgs),
    /// Phase-level migrate-to-gateway flow (emits one Safe bundle per phase)
    #[command(subcommand, name = "migrate-to")]
    MigrateTo(MigrateToCommands),
    /// Migrate a chain off a gateway, back to L1 settlement
    #[command(subcommand, name = "migrate-from")]
    MigrateFrom(MigrateFromCommands),
}

pub use convert::ConvertArgs;
pub use migrate_from::MigrateFromCommands;
pub use migrate_to::MigrateToCommands;

pub(crate) async fn run(args: GatewayCommands) -> anyhow::Result<()> {
    match args {
        GatewayCommands::Convert(cmd) => convert::run_convert(cmd).await,
        GatewayCommands::MigrateTo(cmd) => migrate_to::run_migrate_to(cmd).await,
        GatewayCommands::MigrateFrom(cmd) => migrate_from::run(cmd).await,
    }
}

/// Build a forge script targeting `AdminFunctions.s.sol` with common arguments.
/// Pulls forge args from the runner — the runner already carries the
/// command-line `--sender`/`--gas-limit`/etc. that every stage shares.
pub(super) fn build_admin_functions_script(
    contracts_path: &Path,
    runner: &ForgeRunner,
    sig: &str,
    additional_args: Vec<String>,
) -> anyhow::Result<crate::common::forge::ForgeScript> {
    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = runner.forge_args.clone();
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
