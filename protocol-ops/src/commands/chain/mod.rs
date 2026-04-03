use clap::Subcommand;

use crate::commands::chain::{
    convert_to_gateway::ConvertToGatewayArgs,
    deploy_gateway_transaction_filterer::DeployGatewayTransactionFiltererArgs,
    dump_gateway_force_deployments::DumpGatewayForceDeploymentsArgs,
    finalize_migration_to_gateway::FinalizeMigrationToGatewayArgs, init::ChainInitArgs,
    migrate_to_gateway::MigrateToGatewayArgs, set_upgrade_timestamp::ChainSetUpgradeTimestampArgs,
    upgrade::ChainUpgradeArgs,
};

pub(crate) mod admin_call_builder;
pub(crate) mod convert_to_gateway;
pub(crate) mod deploy_gateway_transaction_filterer;
pub(crate) mod dump_gateway_force_deployments;
pub(crate) mod finalize_migration_to_gateway;
pub(crate) mod init;
pub(crate) mod migrate_to_gateway;
pub(crate) mod set_upgrade_timestamp;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ChainCommands {
    /// Convert a chain to a gateway (settlement layer)
    ConvertToGateway(ConvertToGatewayArgs),
    /// Migrate an existing chain to use a gateway as its settlement layer
    MigrateToGateway(MigrateToGatewayArgs),
    /// Initialize new chain
    Init(ChainInitArgs),
    /// Upgrade chain to new protocol version
    Upgrade(ChainUpgradeArgs),
    /// Set upgrade timestamp so server can detect pending upgrade
    SetUpgradeTimestamp(ChainSetUpgradeTimestampArgs),
    /// Dump `force_deployments_data` for gateway vote preparation (read-only forge script)
    DumpGatewayForceDeployments(DumpGatewayForceDeploymentsArgs),
    /// Deploy gateway transaction filterer and set it on bridgehub
    DeployGatewayTransactionFilterer(DeployGatewayTransactionFiltererArgs),
    /// Finalize chain migration to gateway (confirm L1→L2 transfer after gateway processes it)
    FinalizeMigrationToGateway(FinalizeMigrationToGatewayArgs),
}

pub(crate) async fn run(args: ChainCommands) -> anyhow::Result<()> {
    match args {
        ChainCommands::ConvertToGateway(args) => convert_to_gateway::run(args).await,
        ChainCommands::MigrateToGateway(args) => migrate_to_gateway::run(args).await,
        ChainCommands::FinalizeMigrationToGateway(args) => {
            finalize_migration_to_gateway::run(args).await
        }
        ChainCommands::Init(args) => init::run(args).await,
        ChainCommands::Upgrade(args) => upgrade::run(args).await,
        ChainCommands::SetUpgradeTimestamp(args) => set_upgrade_timestamp::run(args).await,
        ChainCommands::DumpGatewayForceDeployments(args) => {
            dump_gateway_force_deployments::run(args).await
        }
        ChainCommands::DeployGatewayTransactionFilterer(args) => {
            deploy_gateway_transaction_filterer::run(args).await
        }
    }
}
