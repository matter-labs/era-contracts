use alloy::primitives::{Address, B256, keccak256};
use blake2::{Blake2s256, Digest};

/// Derives a deterministic implementation address from a contract's bytecode.
///
/// Mirrors the Solidity `generateRandomAddress` helper in `L2GenesisForceDeploymentsHelper`:
/// ```solidity
/// function generateRandomAddress(bytes memory _bytecodeInfo) internal pure returns (address) {
///     return address(uint160(uint256(keccak256(bytes.concat(bytes32(0), _bytecodeInfo)))));
/// }
/// ```
/// where `_bytecodeInfo` is the 96-byte ABI-encoding of
/// `(blake2s256(bytecode), uint32(length), keccak256(bytecode))`,
/// produced by `Utils.getZKOSBytecodeInfo` (see `deploy-scripts/utils/Utils.sol`).
///
/// The 32 leading zero bytes in the outer keccak preimage ensure the resulting address can never
/// collide with a CREATE or CREATE2 address (both of whose preimages start with a non-zero byte).
pub fn generate_random_address(bytecode: &[u8]) -> Address {
    // blake2s256 hash — matches `Utils.blakeHashBytecode` which calls `scripts/blake2s256.ts`
    let blake_hash: [u8; 32] = Blake2s256::digest(bytecode).into();

    // keccak256 observable hash
    let keccak_hash = keccak256(bytecode);

    // ABI-encode (bytes32, uint32, bytes32) → 96 bytes (each field padded to 32 bytes)
    // [  0.. 32] blake2s256 hash
    // [ 32.. 60] 28 zero bytes (uint32 left-padding)
    // [ 60.. 64] bytecode length as big-endian u32
    // [ 64.. 96] keccak256 hash
    let mut bytecode_info = [0u8; 96];
    bytecode_info[0..32].copy_from_slice(&blake_hash);
    bytecode_info[60..64].copy_from_slice(&(bytecode.len() as u32).to_be_bytes());
    bytecode_info[64..96].copy_from_slice(keccak_hash.as_slice());

    // keccak256(bytes32(0) || bytecodeInfo) → take last 20 bytes as address
    let mut preimage = [0u8; 128];
    // preimage[0..32] is already all zeros
    preimage[32..128].copy_from_slice(&bytecode_info);
    let hash = keccak256(&preimage);
    Address::from_slice(&hash[12..])
}

pub fn l1_contract_name_to_code(contract_name: &str) -> Vec<u8> {
    let path = format!("../../l1-contracts/out/{contract_name}.sol/{contract_name}.json");
    contract_artifact_to_code(&path, contract_name)
}

pub fn da_contract_name_to_code(contract_name: &str) -> Vec<u8> {
    let path = format!("../../da-contracts/out/{contract_name}.sol/{contract_name}.json");
    contract_artifact_to_code(&path, contract_name)
}

fn contract_artifact_to_code(path: &str, contract_name: &str) -> Vec<u8> {
    let file_content = std::fs::read_to_string(path)
        .expect(format!("Failed to read contract bytecode file {}", path).as_str());
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
