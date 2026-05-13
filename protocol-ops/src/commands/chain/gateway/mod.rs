use clap::Subcommand;

pub(crate) mod convert;
pub(crate) mod migrate_from;
pub(crate) mod migrate_to;
pub(crate) mod setup_fee_payer;

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
    /// Opt the signer's EOA in (or out) as the settlement-fee payer for a
    /// specific chain on the Gateway. Sends one tx to `GWAssetTracker`'s
    /// `setSettlementFeePayerAgreement(chainId, agreed)` on the GW L2 RPC.
    #[command(name = "setup-fee-payer")]
    SetupFeePayer(SetupFeePayerArgs),
}

pub use convert::ConvertArgs;
pub use migrate_from::MigrateFromCommands;
pub use migrate_to::MigrateToCommands;
pub use setup_fee_payer::SetupFeePayerArgs;

pub(crate) async fn run(args: GatewayCommands) -> anyhow::Result<()> {
    match args {
        GatewayCommands::Convert(cmd) => convert::run_convert(cmd).await,
        GatewayCommands::MigrateTo(cmd) => migrate_to::run_migrate_to(cmd).await,
        GatewayCommands::MigrateFrom(cmd) => migrate_from::run(cmd).await,
        GatewayCommands::SetupFeePayer(cmd) => setup_fee_payer::run(cmd).await,
    }
}
