use alloy::hex::{self, FromHex};
use alloy::primitives::{keccak256, Address, Bytes, FixedBytes};
use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;

use super::{
    address_from_short_hex, compute_create2_address_zk, compute_hash_with_arguments,
    get_contents_from_github, repo_relative_path,
};

const ERA_CONTRACTS_REPO: &str = "matter-labs/era-contracts";
const ZK_GOVERNANCE_REPO: &str = "zksync-association/zk-governance";
const ALL_CONTRACTS_HASHES_PATH: &str = "AllContractsHashes.json";
const ZK_GOVERNANCE_CONTRACTS: &[&str] = &[
    "l1-contracts/ProtocolUpgradeHandler",
    "l1-contracts/TestnetProtocolUpgradeHandler",
    "l1-contracts/Guardians",
    "l1-contracts/SecurityCouncil",
    "l1-contracts/EmergencyUpgradeBoard",
];

pub struct BytecodeVerifier {
    /// Maps init bytecode hash to the corresponding file name.
    init_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps deployed bytecode hash to the corresponding file name.
    deployed_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps zk bytecode hash to the corresponding file name.
    zk_bytecode_file_by_hash: HashMap<FixedBytes<32>, String>,
    /// Maps a contract’s file name to its zk bytecode hash.
    bytecode_file_to_zkhash: HashMap<String, FixedBytes<32>>,
    /// Maps a contract's file name to its `(evmDeployedBytecodeBlakeHash,
    /// evmDeployedBytecodeLength)` pair — both fields are populated together
    /// in `AllContractsHashes.json` for ZKsync OS-relevant EVM contracts.
    evm_deployed_blake_and_length_by_file: HashMap<String, (FixedBytes<32>, u32)>,
}

impl BytecodeVerifier {
    pub async fn init_v33(
        contracts_commit: Option<&str>,
        zk_governance_commit: &str,
    ) -> anyhow::Result<Self> {
        let mut verifier = if let Some(contracts_commit) = contracts_commit {
            Self::init_from_github(contracts_commit).await
        } else {
            Self::init_from_local()?
        };

        let contract_hashes = ContractHashes::init_from_github_repo(
            zk_governance_commit,
            ZK_GOVERNANCE_REPO,
            ALL_CONTRACTS_HASHES_PATH,
        )
        .await?
        .filter_required(ZK_GOVERNANCE_CONTRACTS)?;
        verifier.extend_from_contract_hashes(contract_hashes);

        Ok(verifier)
    }

    pub fn init_from_local() -> anyhow::Result<Self> {
        let contract_hashes = ContractHashes::init_from_local()?;
        Ok(Self::from_contract_hashes(contract_hashes))
    }

    /// Tries to parse `maybe_bytecode` as init code by testing every possible 32-byte
    /// constructor-argument suffix. Gateway ZKsync OS deployer constructors
    /// carry dynamic structs and selector arrays, and zk-governance
    /// Guardians carries a dynamic members array, so the legacy 0..9 word
    /// scan is too narrow for those CREATE2 deploys.
    pub fn try_parse_bytecode(&self, maybe_bytecode: &[u8]) -> Option<(String, Vec<u8>)> {
        // We do not know how many extra 32-byte arguments there are,
        // so we try all values up to the caller-provided bound.
        let max_args = maybe_bytecode.len() / 32;
        for i in 0..=max_args {
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
        const HEX: &str = "60a060405234801561000f575f5ffd5b506040516102ba3803806102ba83398101604081905261002e9161012e565b5f828451602086015ff590506001600160a01b0381166100945760405162461bcd60e51b815260206004820152601960248201527f437265617465323a204661696c6564206f6e206465706c6f7900000000000000604482015260640160405180910390fd5b60405163f2fde38b60e01b81526001600160a01b03838116600483015282169063f2fde38b906024015f604051808303815f87803b1580156100d4575f5ffd5b505af11580156100e6573d5f5f3e3d5ffd5b505050506001600160a01b0316608052506101f6915050565b634e487b7160e01b5f52604160045260245ffd5b80516001600160a01b0381168114610129575f5ffd5b919050565b5f5f5f60608486031215610140575f5ffd5b83516001600160401b03811115610155575f5ffd5b8401601f81018613610165575f5ffd5b80516001600160401b0381111561017e5761017e6100ff565b604051601f8201601f19908116603f011681016001600160401b03811182821017156101ac576101ac6100ff565b6040528181528282016020018810156101c3575f5ffd5b8160208401602083015e5f60209282018301529086015190945092506101ed905060408501610113565b90509250925092565b60805160af61020b5f395f602e015260af5ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c80638efc30f914602a575b5f5ffd5b60507f000000000000000000000000000000000000000000000000000000000000000081565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f3fea26469706673582212208074d0483a0faace71b7ca2d1e373cc86b18d12221b352166a46778e5730cb5b64736f6c634300081c0033";
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

    /// Returns the (blakeHash, length) pair for a contract's EVM deployed
    /// bytecode, when present in `AllContractsHashes.json`. ZKsync OS L2
    /// `setBytecodeDetailsEVM` consumes all three (blake, length, keccak), so
    /// the full tuple is the right invariant for fixed-address force
    /// deployments where the deployed address is fixed and can't bind the
    /// tuple via address derivation.
    pub fn evm_deployed_blake_and_length(&self, file: &str) -> Option<(FixedBytes<32>, u32)> {
        self.evm_deployed_blake_and_length_by_file
            .get(file)
            .copied()
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
        let contract_hashes = ContractHashes::init_from_github(commit)
            .await
            .expect("Failed to load AllContractsHashes.json from GitHub");
        Self::from_contract_hashes(contract_hashes)
    }

    fn from_contract_hashes(contract_hashes: ContractHashes) -> Self {
        let mut verifier = Self {
            init_bytecode_file_by_hash: HashMap::new(),
            deployed_bytecode_file_by_hash: HashMap::new(),
            zk_bytecode_file_by_hash: HashMap::new(),
            bytecode_file_to_zkhash: HashMap::new(),
            evm_deployed_blake_and_length_by_file: HashMap::new(),
        };

        verifier.extend_from_contract_hashes(contract_hashes);
        verifier.insert_hardcoded_bytecodes();
        verifier
    }

    fn extend_from_contract_hashes(&mut self, contract_hashes: ContractHashes) {
        for contract in contract_hashes.hashes {
            self.insert_contract_hash(contract);
        }
    }

    fn insert_contract_hash(&mut self, contract: ContractHash) {
        if let Some(ref hash) = contract.evm_bytecode_hash {
            let decoded = hex::decode(hash).unwrap_or_else(|_| {
                panic!(
                    "Invalid hex in evm_bytecode_hash for {}",
                    contract.contract_name
                )
            });
            let bytecode_hash = FixedBytes::try_from(decoded.as_slice())
                .expect("Invalid length for FixedBytes (evm_bytecode_hash)");
            self.init_bytecode_file_by_hash
                .insert(bytecode_hash, contract.contract_name.clone());
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
            self.deployed_bytecode_file_by_hash
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
            self.bytecode_file_to_zkhash
                .insert(contract.contract_name.clone(), bytecode_hash);
            self.zk_bytecode_file_by_hash
                .insert(bytecode_hash, contract.contract_name.clone());
        }

        if let (Some(ref blake), Some(length)) = (
            contract.evm_deployed_bytecode_blake_hash.as_ref(),
            contract.evm_deployed_bytecode_length,
        ) {
            let decoded = hex::decode(blake).unwrap_or_else(|_| {
                panic!(
                    "Invalid hex in evm_deployed_bytecode_blake_hash for {}",
                    contract.contract_name
                )
            });
            let blake_hash = FixedBytes::try_from(decoded.as_slice())
                .expect("Invalid length for FixedBytes (evm_deployed_bytecode_blake_hash)");
            self.evm_deployed_blake_and_length_by_file
                .insert(contract.contract_name, (blake_hash, length));
        }
    }

    fn insert_hardcoded_bytecodes(&mut self) {
        // Create2Factory
        self.deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989",
            )
            .unwrap(),
            "Create2Factory".to_string(),
        );
        // TransparentProxyAdmin
        self.deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "0x1d8a3e7186b2285da5ef3ccf4c63a672e91873f2ffdec522a241f72bfcab11c5",
            )
            .unwrap(),
            "TransparentProxyAdmin".to_string(),
        );
        // Hash of the proxy admin used for stage proofs
        // https://sepolia.etherscan.io/address/0x93AEeE8d98fB0873F8fF595fDd534A1f288786D2
        self.deployed_bytecode_file_by_hash.insert(
            FixedBytes::<32>::from_hex(
                "1e651120773914ac75c42598ceac4da0dc3e21709d438937f742ecf916ac30ae",
            )
            .unwrap(),
            "TransparentProxyAdmin".to_string(),
        );
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
    #[serde(rename = "evmDeployedBytecodeBlakeHash")]
    #[serde(default)]
    pub evm_deployed_bytecode_blake_hash: Option<String>,
    #[serde(rename = "evmDeployedBytecodeLength")]
    #[serde(default)]
    pub evm_deployed_bytecode_length: Option<u32>,
    #[serde(rename = "zkBytecodeHash")]
    pub zk_bytecode_hash: Option<String>,
}

#[derive(Debug)]
pub struct ContractHashes {
    pub hashes: Vec<ContractHash>,
}

impl ContractHashes {
    pub fn init_from_local() -> anyhow::Result<Self> {
        const LOCAL_CONTRACT_HASHES_PATH: &str = "AllContractsHashes.json";

        let path = repo_relative_path(LOCAL_CONTRACT_HASHES_PATH);
        let contents = fs::read_to_string(&path).with_context(|| {
            format!(
                "failed to read {}; run `yarn calculate-hashes:fix` or \
                 `npx ts-node scripts/calculate-hashes.ts` from the repository root, or pass \
                 `--contracts-commit` to fetch AllContractsHashes.json from GitHub",
                path.display()
            )
        })?;

        Ok(Self {
            hashes: serde_json::from_str(&contents)
                .context("failed to parse local AllContractsHashes.json")?,
        })
    }

    /// Initializes the contract hashes by fetching and parsing the JSON from GitHub.
    pub async fn init_from_github(commit: &str) -> anyhow::Result<Self> {
        Self::init_from_github_repo(commit, ERA_CONTRACTS_REPO, ALL_CONTRACTS_HASHES_PATH).await
    }

    pub async fn init_from_github_repo(
        commit: &str,
        repo: &str,
        file_path: &str,
    ) -> anyhow::Result<Self> {
        let contents = get_contents_from_github(commit, repo, file_path).await;
        Ok(Self {
            hashes: serde_json::from_str(&contents)
                .with_context(|| format!("failed to parse {file_path} from {repo}@{commit}"))?,
        })
    }

    fn filter_required(self, required_contracts: &[&str]) -> anyhow::Result<Self> {
        let required: HashSet<&str> = required_contracts.iter().copied().collect();
        let mut found: HashSet<String> = HashSet::new();
        let hashes: Vec<_> = self
            .hashes
            .into_iter()
            .filter(|contract| {
                let is_required = required.contains(contract.contract_name.as_str());
                if is_required {
                    found.insert(contract.contract_name.clone());
                }
                is_required
            })
            .collect();

        let missing: Vec<_> = required_contracts
            .iter()
            .copied()
            .filter(|contract| !found.contains(*contract))
            .collect();
        anyhow::ensure!(
            missing.is_empty(),
            "zk-governance AllContractsHashes.json is missing required v33 contract(s): {}",
            missing.join(", ")
        );

        Ok(Self { hashes })
    }
}
