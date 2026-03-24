use clap::Subcommand;
use xshell::Shell;

use crate::commands::chain::{
    execute_simulated_transactions::ChainExecuteSimulatedTransactionsArgs, init::ChainInitArgs,
    set_upgrade_timestamp::ChainSetUpgradeTimestampArgs, upgrade::ChainUpgradeArgs,
};

pub(crate) mod admin_call_builder;
pub(crate) mod execute_simulated_transactions;
pub(crate) mod init;
pub(crate) mod set_upgrade_timestamp;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ChainCommands {
    /// Initialize new chain
    Init(ChainInitArgs),
    /// Upgrade chain to new protocol version
    Upgrade(ChainUpgradeArgs),
    /// Set upgrade timestamp so server can detect pending upgrade
    SetUpgradeTimestamp(ChainSetUpgradeTimestampArgs),
    /// Execute transactions from a protocol-ops --out file (extracts only transactions, runs Forge script)
    ExecuteSimulatedTransactions(ChainExecuteSimulatedTransactionsArgs),
}

pub(crate) async fn run(shell: &Shell, args: ChainCommands) -> anyhow::Result<()> {
    match args {
        ChainCommands::Init(args) => init::run(args, shell).await,
        ChainCommands::Upgrade(args) => upgrade::run(args, shell).await,
        ChainCommands::SetUpgradeTimestamp(args) => set_upgrade_timestamp::run(args, shell).await,
        ChainCommands::ExecuteSimulatedTransactions(args) => {
            execute_simulated_transactions::run(args, shell).await
        }
    }
}
