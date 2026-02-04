use alloy::primitives::{Address, B256};

pub fn l1_contract_name_to_code(contract_name: &str) -> Vec<u8> {
    let path = format!("../../l1-contracts/out/{contract_name}.sol/{contract_name}.json");
    contract_artifact_to_code(&path, contract_name)
}

pub fn da_contract_name_to_code(contract_name: &str) -> Vec<u8> {
    let path = format!("../../da-contracts/out/{contract_name}.sol/{contract_name}.json");
    contract_artifact_to_code(&path, contract_name)
}

fn contract_artifact_to_code(path: &str, contract_name: &str) -> Vec<u8> {
    let file_content =
        std::fs::read_to_string(path).expect(format!("Failed to read contract bytecode file {}", path).as_str());
    let artifact: serde_json::Value =
        serde_json::from_str(&file_content).expect("Failed to parse JSON file");

    let deployed_bytecode = artifact["deployedBytecode"]["object"]
        .as_str()
        .filter(|&bytecode| bytecode != "0x")
        .expect(&format!(
            "No deployed bytecode found in artifact for contract {}",
            contract_name
        ));

    hex::decode(&deployed_bytecode[2..]).expect("Failed to decode deployed bytecode")
}

// Helper to convert Address (20 bytes) to B256 (32 bytes, left-padded with zeros)
pub fn address_to_b256(addr: &Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..].copy_from_slice(addr.0.as_slice());
    B256::from(bytes)
}
