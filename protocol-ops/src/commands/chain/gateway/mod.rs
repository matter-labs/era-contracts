use clap::Subcommand;

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
