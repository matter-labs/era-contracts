use alloy::hex::{self, FromHex};
use alloy::primitives::{keccak256, Address, Bytes, FixedBytes};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::{
    address_from_short_hex, compute_create2_address_zk, compute_hash_with_arguments,
    get_contents_from_github,
};

pub struct BytecodeVerifier {
    /// Maps init bytecode hash to the corresponding file name.
    init_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps deployed bytecode hash to the corresponding file name.
    deployed_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps zk bytecode hash to the corresponding file name.
    zk_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps a contract’s file name to its zk bytecode hash.
    bytecode_file_to_zkhash: HashMap<String, FixedBytes<32>>,
}

impl BytecodeVerifier {
    /// Tries to parse `maybe_bytecode` as init code by testing 0 to 9 arguments.
    ///
    /// On success, returns a tuple of the contract file name and the extra argument
    /// bytes appended at the end of the bytecode.
    pub fn try_parse_bytecode(&self, maybe_bytecode: &[u8]) -> Option<(String, Vec<u8>)> {
        // We do not know how many extra 32-byte arguments there are,
        // so we try all values from 0 to 9.
        for i in 0..10 {
            // Skip if there isn’t even enough data for i arguments.
            if maybe_bytecode.len() < 32 * i {
                continue;
            }

            if let Some(hash) =
                compute_hash_with_arguments(&Bytes::copy_from_slice(maybe_bytecode), i)
            {
                if let Some(file_name) = self.evm_init_bytecode_hash_to_file(&hash) {
                    let args_start = maybe_bytecode.len() - 32 * i;
                    return Some((file_name.clone(), maybe_bytecode[args_start..].to_vec()));
                }
            }
        }
        None
    }

    /// Returns the create2 and transfer bytecode.
    ///
    /// This function decodes a hard-coded hex string and cross-checks its hash against
    /// an expected mapping.
    fn get_create2_and_transfer_bytecode(&self) -> Vec<u8> {
        const HEX: &str = "60a060405234801561000f575f5ffd5b506040516102ba3803806102ba83398101604081905261002e9161012e565b5f828451602086015ff590506001600160a01b0381166100945760405162461bcd60e51b815260206004820152601960248201527f437265617465323a204661696c6564206f6e206465706c6f7900000000000000604482015260640160405180910390fd5b60405163f2fde38b60e01b81526001600160a01b03838116600483015282169063f2fde38b906024015f604051808303815f87803b1580156100d4575f5ffd5b505af11580156100e6573d5f5f3e3d5ffd5b505050506001600160a01b0316608052506101f6915050565b634e487b7160e01b5f52604160045260245ffd5b80516001600160a01b0381168114610129575f5ffd5b919050565b5f5f5f60608486031215610140575f5ffd5b83516001600160401b03811115610155575f5ffd5b8401601f81018613610165575f5ffd5b80516001600160401b0381111561017e5761017e6100ff565b604051601f8201601f19908116603f011681016001600160401b03811182821017156101ac576101ac6100ff565b6040528181528282016020018810156101c3575f5ffd5b8160208401602083015e5f60209282018301529086015190945092506101ed905060408501610113565b90509250925092565b60805160af61020b5f395f602e015260af5ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c80638efc30f914602a575b5f5ffd5b60507f000000000000000000000000000000000000000000000000000000000000000081565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f3fea26469706673582212200c236b856dbe3954f4c4a10f1a3c34a6e4fcbb381a9a42566401434e35e485e664736f6c634300081c0033";
        let bytecode =
            hex::decode(HEX).expect("Invalid hex encoding for create2 and transfer bytecode");

        // Cross-check the resulting bytecode hash against the expected file name.
        let hash = keccak256(&bytecode);
        let expected_file = "l1-contracts/Create2AndTransfer";
        let actual_file = self
            .evm_init_bytecode_hash_to_file(&hash)
            .expect("Missing mapping for create2 and transfer bytecode");
        // If this fails, then you have to update the 'HEX' from above - by taking it from the l1-contracts/out/Create2AndTransfer.sol directory.
        // Take 'bytecode.object' value.
        assert_eq!(
            actual_file, expected_file,
            "Bytecode file mismatch for create2 and transfer"
        );

        bytecode
    }

    /// Checks whether the provided `slice` starts with the create2 and transfer bytecode.
    ///
    /// If so, returns the remainder of the slice (after the prefix).
    pub fn is_create2_and_transfer_bytecode_prefix<'a>(&self, slice: &'a [u8]) -> Option<&'a [u8]> {
        let prefix = self.get_create2_and_transfer_bytecode();
        if slice.len() < prefix.len() {
            return None;
        }
        if &slice[..prefix.len()] == prefix.as_slice() {
            Some(&slice[prefix.len()..])
        } else {
            None
        }
    }

    /// Returns the file name corresponding to the given init bytecode hash.
    pub fn evm_init_bytecode_hash_to_file(
        &self,
        bytecode_hash: &FixedBytes<32>,
    ) -> Option<&String> {
        self.init_bytecode_file_by_hash.get(bytecode_hash)
    }

    /// Returns the file name corresponding to the given deployed bytecode hash.
    pub fn evm_deployed_bytecode_hash_to_file(
        &self,
        bytecode_hash: &FixedBytes<32>,
    ) -> Option<&String> {
        self.deployed_bytecode_file_by_hash.get(bytecode_hash)
    }

    /// Returns the file name corresponding to the given zk bytecode hash.
    pub fn zk_bytecode_hash_to_file(&self, bytecode_hash: &FixedBytes<32>) -> Option<&String> {
        self.zk_bytecode_file_by_hash.get(bytecode_hash)
    }

    /// Returns the zk bytecode hash that corresponds to the file
    pub fn file_to_zk_bytecode_hash(&self, file: &str) -> Option<&FixedBytes<32>> {
        self.bytecode_file_to_zkhash.get(file)
    }

    /// Inserts an entry for the given deployed bytecode hash and file name.
    pub fn insert_evm_deployed_bytecode_hash(
        &mut self,
        bytecode_hash: FixedBytes<32>,
        file: String,
    ) {
        self.deployed_bytecode_file_by_hash
            .insert(bytecode_hash, file);
    }

    pub(crate) fn compute_expected_address_for_file(&self, file: &str) -> Address {
        let code = self
            .file_to_zk_bytecode_hash(file)
            .unwrap_or_else(|| panic!("Bytecode not found for file: {}", file));
        compute_create2_address_zk(
            // Create2Factory address
            address_from_short_hex("10000"),
            FixedBytes::ZERO,
            *code,
            keccak256([]),
        )
    }

    /// Initializes the verifier from contract hashes obtained from GitHub.
    pub async fn init_from_github(commit: &str) -> Self {
        let mut init_bytecode_file_by_hash = HashMap::new();
        let mut deployed_bytecode_file_by_hash = HashMap::new();
        let mut bytecode_file_to_zkhash = HashMap::new();
        let mut zk_bytecode_file_by_hash = HashMap::new();

        let contract_hashes = ContractHashes::init_from_github(commit).await;
        for contract in contract_hashes.hashes {
            if let Some(ref hash) = contract.evm_bytecode_hash {
                let decoded = hex::decode(hash).unwrap_or_else(|_| {
                    panic!(
                        "Invalid hex in evm_bytecode_hash for {}",
                        contract.contract_name
                    )
                });
                let bytecode_hash = FixedBytes::try_from(decoded.as_slice())
                    .expect("Invalid length for FixedBytes (evm_bytecode_hash)");
                init_bytecode_file_by_hash.insert(bytecode_hash, contract.contract_name.clone());
            }

            if let Some(ref hash) = contract.evm_deployed_bytecode_hash {
                let decoded = hex::decode(hash).unwrap_or_else(|_| {
                    panic!(
                        "Invalid hex in evm_deployed_bytecode_hash for {}",
                        contract.contract_name
                    )
                });
                let bytecode_hash = FixedBytes::try_from(decoded.as_slice())
                    .expect("Invalid length for FixedBytes (evm_deployed_bytecode_hash)");
                deployed_bytecode_file_by_hash
                    .insert(bytecode_hash, contract.contract_name.clone());
            }

            if let Some(ref hash) = contract.zk_bytecode_hash {
                let decoded = hex::decode(hash).unwrap_or_else(|_| {
                    panic!(
                        "Invalid hex in zk_bytecode_hash for {}",
                        contract.contract_name
                    )
                });
                let bytecode_hash = FixedBytes::try_from(decoded.as_slice())
                    .expect("Invalid length for FixedBytes (zk_bytecode_hash)");
                bytecode_file_to_zkhash.insert(contract.contract_name.clone(), bytecode_hash);
                zk_bytecode_file_by_hash.insert(bytecode_hash, contract.contract_name);
            }
        }

        // Create2Factory
        deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989",
            )
            .unwrap(),
            "Create2Factory".to_string(),
        );
        // TransparentProxyAdmin
        deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "0x1d8a3e7186b2285da5ef3ccf4c63a672e91873f2ffdec522a241f72bfcab11c5",
            )
            .unwrap(),
            "TransparentProxyAdmin".to_string(),
        );
        // Hash of the proxy admin used for stage proofs
        // https://sepolia.etherscan.io/address/0x93AEeE8d98fB0873F8fF595fDd534A1f288786D2
        deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "1e651120773914ac75c42598ceac4da0dc3e21709d438937f742ecf916ac30ae",
            )
            .unwrap(),
            "TransparentProxyAdmin".to_string(),
        );

        Self {
            init_bytecode_file_by_hash,
            deployed_bytecode_file_by_hash,
            zk_bytecode_file_by_hash,
            bytecode_file_to_zkhash,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContractHash {
    #[serde(rename = "contractName")]
    pub contract_name: String,
    #[serde(rename = "evmBytecodeHash")]
    pub evm_bytecode_hash: Option<String>,
    #[serde(rename = "evmDeployedBytecodeHash")]
    pub evm_deployed_bytecode_hash: Option<String>,
    #[serde(rename = "zkBytecodeHash")]
    pub zk_bytecode_hash: Option<String>,
}

#[derive(Debug)]
pub struct ContractHashes {
    pub hashes: Vec<ContractHash>,
}

impl ContractHashes {
    /// Initializes the contract hashes by fetching and parsing the JSON from GitHub.
    pub async fn init_from_github(commit: &str) -> Self {
        let contents = Self::get_contents(commit).await;
        Self {
            hashes: serde_json::from_str(&contents)
                .expect("Failed to parse AllContractsHashes.json from GitHub"),
        }
    }

    async fn get_contents(commit: &str) -> String {
        get_contents_from_github(
            commit,
            "matter-labs/era-contracts",
            "AllContractsHashes.json",
        )
        .await
    }
}
