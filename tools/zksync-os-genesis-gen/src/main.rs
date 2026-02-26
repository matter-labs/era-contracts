use alloy::primitives::{b256, bytes};
use crate::genesis::build_genesis_root_hash;
use crate::types::{Genesis, InitialGenesisInput};
use structopt::StructOpt;
mod consts;
mod genesis;
mod types;
mod utils;

const PATH_TO_LOCAL_GENESIS: &str = "../../configs/genesis/zksync-os/latest.json";

#[derive(StructOpt, Debug)]
#[structopt(name = "zksync-os-genesis-gen")]
struct Opt {
    /// Output file path
    #[structopt(long = "output-file", default_value = "../../zksync-os-genesis.json")]
    output_file: String,
    /// Execution version (CLI > env > default)
    #[structopt(long = "execution-version", env = "EXECUTION_VERSION")]
    execution_version: Option<u32>,
}

fn main() -> anyhow::Result<()> {
    let opt = Opt::from_args();
    println!("Output file: {}", opt.output_file);

    let mut genesis = update_local_genesis()?;
    if let Some(execution_version) = opt.execution_version {
        println!("Setting execution version to {}", execution_version);
        genesis.execution_version = execution_version;
    }

    let json = serde_json::to_string_pretty(&genesis)?;
    std::fs::write(PATH_TO_LOCAL_GENESIS, &json)?;
    std::fs::write(opt.output_file, &json)?;

    Ok(())
}

fn update_local_genesis() -> anyhow::Result<Genesis> {
    // Load the original genesis file for getting the correct version fields
    let mut genesis: Genesis = serde_json::from_str(
        &std::fs::read_to_string(PATH_TO_LOCAL_GENESIS).expect("Failed to read local genesis file"),
    )?;
    genesis.initial_genesis = InitialGenesisInput::local();
    genesis.genesis_root = build_genesis_root_hash(&genesis.initial_genesis)?;
    genesis.additional_preimages = Some(vec![(
        b256!("0x49d1759eb6d2cd7eda55639c305253810d31f5d50cea1ede0be519ccbb1d8a93"),
        bytes!("0x0000000000000000000000000000000000000000000000000000000000000000ffffffffffffffffffffffffffffffff00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    )]);
    Ok(genesis)
}
