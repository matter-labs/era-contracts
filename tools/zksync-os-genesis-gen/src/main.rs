use std::collections::BTreeMap;

use structopt::StructOpt;
use alloy::primitives::{Address, FixedBytes, B256};

use crate::types::{build_genesis, InitialGenesisInput};
mod types;

const L2_COMPLEX_UPGRADER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!("000000000000000000000000000000000000800f")));
const L2_GENESIS_UPGRADE: Address = Address(FixedBytes::<20>(hex_literal::hex!("0000000000000000000000000000000000010001")));
const L2_WRAPPED_BASE_TOKEN: Address = Address(FixedBytes::<20>(hex_literal::hex!("0000000000000000000000000000000000010007")));
const SYSTEM_CONTRACT_PROXY_ADMIN: Address = Address(FixedBytes::<20>(hex_literal::hex!("000000000000000000000000000000000001000c")));
// keccak256("L2_COMPLEX_UPGRADER_IMPL_ADDR") - 1.
// We need it predeployed to make the genesis upgrade work at all.
const L2_COMPLEX_UPGRADER_IMPL_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!("d704e29df32c189b8613f79fcc043b2dc01d5f53")));

const SYSTEM_PROXY_ADMIN_OWNER_SLOT: B256 = B256::ZERO;
const EIP1967_IMPLEMENTATION_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
));
const EIP1967_ADMIN_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
));

const INITIAL_CONTRACTS: [(Address, &str); 5] = [
    (L2_COMPLEX_UPGRADER_ADDR, "SystemContractProxy"),
    (L2_GENESIS_UPGRADE, "L2GenesisUpgrade"),
    (L2_WRAPPED_BASE_TOKEN, "L2WrappedBaseToken"),
    (SYSTEM_CONTRACT_PROXY_ADMIN, "SystemContractProxyAdmin"),
    (L2_COMPLEX_UPGRADER_IMPL_ADDR, "L2ComplexUpgrader"),
];

fn bytecode_to_code(contract_name: &str) -> Vec<u8> {
    let path = format!(
        "../../l1-contracts/out/{contract_name}.sol/{contract_name}.json"
    );
    let file_content = std::fs::read_to_string(&path).expect("Failed to read contract bytecode file");
    let artifact: serde_json::Value = serde_json::from_str(&file_content).expect("Failed to parse JSON file");

    let deployed_bytecode = artifact["deployedBytecode"]["object"]
        .as_str()
        .filter(|&bytecode| bytecode != "0x")
        .expect(&format!("No deployed bytecode found in artifact for contract {}", contract_name));

    hex::decode(&deployed_bytecode[2..]).expect("Failed to decode deployed bytecode")
}


// Helper to convert Address (20 bytes) to B256 (32 bytes, left-padded with zeros)
fn address_to_b256(addr: &Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..].copy_from_slice(addr.0.as_slice());
        B256::from(bytes)
    }

fn construct_additional_storage() -> BTreeMap<Address, BTreeMap<B256, B256>> {
    use alloy::primitives::B256;
    use std::collections::BTreeMap;

    let mut map: BTreeMap<Address, BTreeMap<B256, B256>> = BTreeMap::new();

    let mut system_contract_proxy_admin_storage = BTreeMap::new();
    system_contract_proxy_admin_storage.insert(SYSTEM_PROXY_ADMIN_OWNER_SLOT, address_to_b256(&L2_COMPLEX_UPGRADER_ADDR));
    map.insert(SYSTEM_CONTRACT_PROXY_ADMIN, system_contract_proxy_admin_storage);

    let mut l2_complex_upgrader_storage = BTreeMap::new();
    l2_complex_upgrader_storage.insert(EIP1967_IMPLEMENTATION_SLOT, address_to_b256(&L2_COMPLEX_UPGRADER_IMPL_ADDR));
    l2_complex_upgrader_storage.insert(EIP1967_ADMIN_SLOT, address_to_b256(&SYSTEM_CONTRACT_PROXY_ADMIN));
    map.insert(L2_COMPLEX_UPGRADER_ADDR, l2_complex_upgrader_storage);

    map
}

#[derive(StructOpt, Debug)]
#[structopt(name = "zksync-os-genesis-gen")]
struct Opt {
    /// Output file path
    #[structopt(long = "output-file", default_value = "../../zksync-os-genesis.json")]
    output_file: String,
    /// Execution version (CLI > env > default)
    #[structopt(long = "execution-version", env = "EXECUTION_VERSION", default_value = "3")]
    execution_version: u32,
}

fn main() -> anyhow::Result<()> {
    let opt = Opt::from_args();
    println!("Output file: {}", opt.output_file);

    let initial_genesis_input = InitialGenesisInput {
        initial_contracts: INITIAL_CONTRACTS
            .iter()
            .map(|(addr, name)| {
                let code = bytecode_to_code(name);
                ( *addr, alloy::primitives::Bytes::from(code) )
            })
            .collect(),
        additional_storage: construct_additional_storage(),
        additional_storage_raw: Default::default(),
        execution_version: opt.execution_version,
    };

    let result = build_genesis(initial_genesis_input)?;

    let json = serde_json::to_string_pretty(&result)?;
    std::fs::write(&opt.output_file, json)?;

    Ok(())
}
