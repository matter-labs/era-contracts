use clap::Subcommand;

use crate::commands::chain::{
    gateway::GatewayCommands, init::ChainInitArgs,
    set_da_validator_pair::ChainSetDaValidatorPairArgs,
    set_upgrade_timestamp::ChainSetUpgradeTimestampArgs, upgrade::ChainUpgradeArgs,
    validator::ChainValidatorArgs,
};

pub(crate) mod gateway;
pub(crate) mod init;
pub(crate) mod set_da_validator_pair;
pub(crate) mod set_upgrade_timestamp;
pub(crate) mod upgrade;
pub(crate) mod validator;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ChainCommands {
    /// Initialize new chain
    Init(ChainInitArgs),
    /// Upgrade chain to new protocol version
    Upgrade(ChainUpgradeArgs),
    /// Set upgrade timestamp so server can detect pending upgrade
    SetUpgradeTimestamp(ChainSetUpgradeTimestampArgs),
    /// Set the chain's DA validator pair (L1 validator + L2 commitment scheme).
    /// Use post-upgrade, when the upgrade resets the chain's DA validator and
    /// the operator must re-set it before the chain can commit batches.
    SetDaValidatorPair(ChainSetDaValidatorPairArgs),
    /// Add a validator to the chain's ValidatorTimelock (all batch operator roles)
    AddValidator(ChainValidatorArgs),
    /// Remove a validator from the chain's ValidatorTimelock (revokes all batch operator roles)
    RemoveValidator(ChainValidatorArgs),
    /// Gateway operations: converting a chain into a gateway or migrating to one
    #[command(subcommand)]
    Gateway(GatewayCommands),
}

pub(crate) async fn run(args: ChainCommands) -> anyhow::Result<()> {
    match args {
        ChainCommands::Init(args) => init::run(args).await,
        ChainCommands::Upgrade(args) => upgrade::run(args).await,
        ChainCommands::SetUpgradeTimestamp(args) => set_upgrade_timestamp::run(args).await,
        ChainCommands::SetDaValidatorPair(args) => set_da_validator_pair::run(args).await,
        ChainCommands::AddValidator(args) => validator::run_add(args).await,
        ChainCommands::RemoveValidator(args) => validator::run_remove(args).await,
        ChainCommands::Gateway(cmd) => gateway::run(cmd).await,
    }
}
