use clap::Subcommand;

use crate::commands::genesis::gen::GenesisGenArgs;

pub(crate) mod gen;

#[derive(Subcommand, Debug)]
pub enum GenesisCommands {
    /// Generate genesis.json from built L1/DA contracts (same as zksync-os-genesis-gen)
    Gen(GenesisGenArgs),
}

pub(crate) async fn run(args: GenesisCommands) -> anyhow::Result<()> {
    match args {
        GenesisCommands::Gen(args) => gen::run(args),
    }
}
