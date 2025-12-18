use crate::genesis::build_genesis_root_hash;
use crate::types::{Genesis, InitialGenesisInput};
mod consts;
mod genesis;
mod types;
mod utils;

fn main() -> anyhow::Result<()> {
    update_local_genesis()?;
    Ok(())
}

fn update_local_genesis() -> anyhow::Result<()> {
    const PATH_TO_LOCAL_GENESIS: &str = "../../configs/genesis/zksync-os/latest.json";
    // Load the original genesis file for getting the correct version fields
    let mut genesis: Genesis = serde_json::from_str(
        &std::fs::read_to_string(PATH_TO_LOCAL_GENESIS).expect("Failed to read local genesis file"),
    )?;
    genesis.initial_genesis = InitialGenesisInput::local();
    genesis.genesis_root = build_genesis_root_hash(&genesis.initial_genesis)?;

    let json = serde_json::to_string_pretty(&genesis)?;
    std::fs::write(PATH_TO_LOCAL_GENESIS, json)?;

    Ok(())
}
