use clap::Subcommand;

use crate::commands::dev::execute_transactions::DevExecuteTransactionsArgs;

pub(crate) mod execute_transactions;

#[derive(Subcommand, Debug)]
pub enum DevCommands {
    /// Execute simulated transactions from a protocol-ops --out file
    ExecuteTransactions(DevExecuteTransactionsArgs),
}

pub(crate) async fn run(args: DevCommands) -> anyhow::Result<()> {
    match args {
        DevCommands::ExecuteTransactions(args) => execute_transactions::run(args).await,
    }
}
