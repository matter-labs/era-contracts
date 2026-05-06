use alloy::consensus::Transaction;
use alloy::hex::FromHex;
use alloy::primitives::{keccak256, Address, FixedBytes, TxHash, U256};
use alloy::providers::{Provider, RootProvider};
use alloy::sol;
use alloy::sol_types::SolCall;
use anyhow::Context;
use std::collections::HashMap;
use Bridgehub::requestL2TransactionDirectCall;

use super::super::elements::UpgradeOutput;

use super::bytecode_verifier::BytecodeVerifier;
use super::{address_from_short_hex, compute_create2_address_evm, compute_create2_address_zk};

sol! {
    #[derive(Debug)]
    struct L2TransactionRequestDirect {
        uint256 chainId;
        uint256 mintValue;
        address l2Contract;
        uint256 l2Value;
        bytes l2Calldata;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdataByteLimit;
        bytes[] factoryDeps;
        address refundRecipient;
    }

    #[sol(rpc)]
    contract Bridgehub {
        address public sharedBridge;
        address public admin;
        address public owner;
        mapping(uint256 _chainId => address) public chainTypeManager;
        function getHyperchain(uint256 _chainId) external view returns (address chainAddress);
        function getAllZKChainChainIDs() external view returns (uint256[] memory);
        function assetRouter() external view returns (address);
        function getZKChain(uint256 _chainId) external view returns (address chainAddress);
        function baseToken(uint256 _chainId) external view returns (address);
        function requestL2TransactionDirect(
            L2TransactionRequestDirect calldata _request
        ) external payable returns (bytes32 canonicalTxHash);
    }

    #[sol(rpc)]
    contract L1AssetRouter {
        function legacyBridge() public returns (address);
        function L1_WETH_TOKEN() public returns (address);
        function L1_NULLIFIER() public returns (address);

        function nativeTokenVault() public returns (address);
    }

    #[sol(rpc)]
    contract ChainTypeManager {
        function getHyperchain(uint256 _chainId) public view returns (address);
        address public validatorTimelock;
        function protocolVersion() external view returns (uint256);
        function isZKsyncOS() external view returns (bool);
    }

    function create2AndTransferParams(bytes memory bytecode, bytes32 salt, address owner);

    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address);
}

const EIP1967_PROXY_ADMIN_SLOT: &str =
    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

#[derive(Debug)]
pub struct BridgehubInfo {
    pub shared_bridge: Address,
    pub legacy_bridge: Address,
    pub stm_address: Address,
    pub transparent_proxy_admin: Address,
    pub l1_weth_token_address: Address,
    pub ecosystem_admin: Address,
    pub bridgehub_addr: Address,
    pub validator_timelock: Address,
    pub era_address: Address,
    pub native_token_vault: Address,
    pub l1_nullifier: Address,
    pub l1_asset_router_proxy_addr: Address,
    pub gateway_base_token_addr: Address,
}

pub struct NetworkVerifier {
    pub l1_provider: RootProvider,
    pub l2_chain_id: u64,
    pub l1_chain_id: u64,
    pub gateway_chain_id: u64,
    pub gw_provider: RootProvider,

    // todo: maybe merge into one struct.
    pub create2_known_bytecodes: HashMap<Address, String>,
    pub create2_constructor_params: HashMap<Address, Vec<u8>>,
}

impl NetworkVerifier {
    pub fn new_v31(l1_rpc: String) -> anyhow::Result<Self> {
        let l1_provider = RootProvider::new_http(l1_rpc.parse().context("invalid L1 RPC URL")?);
        let gw_provider = l1_provider.clone();

        Ok(Self {
            l1_provider,
            l2_chain_id: 0,
            l1_chain_id: 0,
            gateway_chain_id: 0,
            gw_provider,
            create2_constructor_params: HashMap::new(),
            create2_known_bytecodes: HashMap::new(),
        })
    }

    pub async fn new(
        l1_rpc: String,
        l2_chain_id: u64,
        gateway_chain_id: u64,
        gateway_rpc: String,
        bytecode_verifier: &BytecodeVerifier,
        config: &UpgradeOutput,
        bridgehub_address: &Address,
    ) -> Self {
        let mut create2_constructor_params = HashMap::new();
        let mut create2_known_bytecodes = HashMap::new();
        let l1_provider = RootProvider::new_http(l1_rpc.parse().unwrap());
        let gw_provider = RootProvider::new_http(gateway_rpc.parse().unwrap());

        if gw_provider.get_chain_id().await.unwrap() != gateway_chain_id {
            panic!("Incorrect gateway provider")
        }

        println!(
            "Adding {} transactions from create2",
            config.transactions.len()
        );

        for transaction in &config.transactions {
            if let Some((address, contract, constructor_param)) = check_create2_deploy(
                l1_provider.clone(),
                transaction,
                &config.create2_factory_addr,
                &config.create2_factory_salt,
                bytecode_verifier,
            )
            .await
            {
                if create2_constructor_params
                    .insert(address, constructor_param)
                    .is_some()
                {
                    panic!("Duplicate deployment for {:#?}", address)
                }

                if create2_known_bytecodes
                    .insert(address, contract.clone())
                    .is_some()
                {
                    panic!("Duplicate deployment for {:#?}", address)
                }
            }

            if let Some((address, contract, constructor_param)) = check_gw_create2_deploy(
                l1_provider.clone(),
                bridgehub_address,
                transaction,
                bytecode_verifier,
            )
            .await
            {
                if create2_constructor_params
                    .insert(address, constructor_param)
                    .is_some()
                {
                    panic!("Duplicate deployment for {:#?}", address)
                }

                if create2_known_bytecodes
                    .insert(address, contract.clone())
                    .is_some()
                {
                    panic!("Duplicate deployment for {:#?}", address)
                }
            }
        }

        Self {
            l1_chain_id: l1_provider.get_chain_id().await.unwrap(),
            l1_provider,
            l2_chain_id,
            gateway_chain_id,
            gw_provider,
            create2_constructor_params,
            create2_known_bytecodes,
        }
    }

    pub fn get_era_chain_id(&self) -> u64 {
        self.l2_chain_id
    }

    pub fn get_l1_chain_id(&self) -> u64 {
        self.l1_chain_id
    }

    pub fn get_gateway_chain_id(&self) -> u64 {
        self.gateway_chain_id
    }

    pub async fn get_bytecode_hash_at(&self, address: &Address) -> FixedBytes<32> {
        let code = self.l1_provider.get_code_at(*address).await.unwrap();
        if code.len() == 0 {
            // If address has no bytecode - we return formal 0s.
            FixedBytes::ZERO
        } else {
            keccak256(&code)
        }
    }

    pub async fn get_chain_diamond_proxy(&self, stm_addr: Address, era_chain_id: u64) -> Address {
        let ctm = ChainTypeManager::new(stm_addr, self.l1_provider.clone());

        ctm.getHyperchain(U256::from(era_chain_id))
            .call()
            .await
            .unwrap()
    }

    pub async fn storage_at(&self, address: &Address, key: &FixedBytes<32>) -> FixedBytes<32> {
        let storage = self
            .l1_provider
            .get_storage_at(*address, U256::from_be_bytes(key.0))
            .await
            .unwrap();

        FixedBytes::from_slice(&storage.to_be_bytes_vec())
    }

    pub async fn get_storage_at(&self, address: &Address, key: u8) -> FixedBytes<32> {
        let storage = self
            .l1_provider
            .get_storage_at(*address, U256::from(key))
            .await
            .unwrap();

        FixedBytes::from_slice(&storage.to_be_bytes_vec())
    }

    pub fn get_l1_provider(&self) -> RootProvider {
        self.l1_provider.clone()
    }

    pub fn get_gw_provider(&self) -> RootProvider {
        self.gw_provider.clone()
    }

    pub async fn try_get_l1_chain_id(&self) -> anyhow::Result<u64> {
        self.l1_provider
            .get_chain_id()
            .await
            .context("failed to fetch L1 chain id")
    }

    pub async fn try_get_ctm_protocol_version(&self, ctm_addr: Address) -> anyhow::Result<U256> {
        let ctm = ChainTypeManager::new(ctm_addr, self.l1_provider.clone());
        ctm.protocolVersion()
            .call()
            .await
            .context("failed to fetch CTM protocolVersion")
    }

    pub async fn try_get_ctm_is_zksync_os(&self, ctm_addr: Address) -> anyhow::Result<bool> {
        let ctm = ChainTypeManager::new(ctm_addr, self.l1_provider.clone());
        ctm.isZKsyncOS()
            .call()
            .await
            .context("failed to fetch CTM isZKsyncOS")
    }

    pub async fn try_get_chain_diamond_from_bridgehub(
        &self,
        bridgehub_addr: Address,
        chain_id: U256,
    ) -> anyhow::Result<Address> {
        let bridgehub = Bridgehub::new(bridgehub_addr, self.l1_provider.clone());
        bridgehub
            .getZKChain(chain_id)
            .call()
            .await
            .context("failed to fetch chain diamond from Bridgehub")
    }

    pub async fn get_proxy_admin(&self, addr: Address) -> Address {
        let addr_as_bytes = self
            .storage_at(
                &addr,
                &FixedBytes::<32>::from_hex(EIP1967_PROXY_ADMIN_SLOT).unwrap(),
            )
            .await;
        Address::from_slice(&addr_as_bytes[12..])
    }

    pub async fn get_bridgehub_info(&self, bridgehub_addr: Address) -> BridgehubInfo {
        let l1_provider = &self.get_l1_provider();

        let bridgehub = Bridgehub::new(bridgehub_addr, l1_provider);

        let shared_bridge_address = bridgehub.sharedBridge().call().await.unwrap();

        let shared_bridge = L1AssetRouter::new(shared_bridge_address, l1_provider);

        let era_chain_id = self.get_era_chain_id();

        let stm_address = bridgehub
            .chainTypeManager(era_chain_id.try_into().unwrap())
            .call()
            .await
            .unwrap();
        let chain_type_manager = ChainTypeManager::new(stm_address, l1_provider);
        let era_address = chain_type_manager
            .getHyperchain(U256::from(era_chain_id))
            .call()
            .await
            .unwrap();
        let validator_timelock = chain_type_manager.validatorTimelock().call().await.unwrap();

        let ecosystem_admin = bridgehub.admin().call().await.unwrap();

        let transparent_proxy_admin = self.get_proxy_admin(bridgehub_addr).await;

        let legacy_bridge = shared_bridge.legacyBridge().call().await.unwrap();

        let l1_weth_token_address = shared_bridge.L1_WETH_TOKEN().call().await.unwrap();

        let native_token_vault = shared_bridge.nativeTokenVault().call().await.unwrap();

        let l1_nullifier = shared_bridge.L1_NULLIFIER().call().await.unwrap();

        let l1_asset_router_proxy_addr = bridgehub.assetRouter().call().await.unwrap();

        let gateway_base_token_addr = bridgehub
            .baseToken(U256::from(self.get_gateway_chain_id()))
            .call()
            .await
            .unwrap();

        BridgehubInfo {
            shared_bridge: shared_bridge_address,
            legacy_bridge,
            stm_address,
            transparent_proxy_admin,
            l1_weth_token_address,
            ecosystem_admin,
            bridgehub_addr,
            validator_timelock,
            era_address,
            native_token_vault,
            l1_nullifier,
            l1_asset_router_proxy_addr,
            gateway_base_token_addr,
        }
    }
}

/// Fetches the `transaction` and tries to parse it as a CREATE2 deployment
/// transaction.
/// If successful, it returns a tuple of three items: the address of the deployed contract,
/// the path to the contract and its constructor params.
async fn check_create2_deploy(
    l1_provider: RootProvider,
    transaction: &str,
    expected_create2_address: &Address,
    expected_create2_salt: &FixedBytes<32>,
    bytecode_verifier: &BytecodeVerifier,
) -> Option<(Address, String, Vec<u8>)> {
    let tx_hash: TxHash = transaction.parse().unwrap();

    let tx = l1_provider
        .get_transaction_by_hash(tx_hash)
        .await
        .unwrap()
        .unwrap();

    if tx.to() != Some(*expected_create2_address) {
        return None;
    }

    // There are two types of CREATE2 deployments that were used:
    // - Usual, using CREATE2Factory directly.
    // - By using the `Create2AndTransfer` contract.
    // We will try both here.

    let salt = &tx.input()[0..32];
    if salt != expected_create2_salt.as_slice() {
        println!("Salt mismatch: {:?} != {:?}", salt, expected_create2_salt);
        return None;
    }

    if let Some((name, params)) = bytecode_verifier.try_parse_bytecode(&tx.input()[32..]) {
        let addr = compute_create2_address_evm(
            tx.to().unwrap(),
            FixedBytes::<32>::from_slice(salt),
            keccak256(&tx.input()[32..]),
        );
        return Some((addr, name, params));
    };

    let bytecode_input = &tx.input()[32..];

    // Okay, this may be the `Create2AndTransfer` method.
    if let Some(create2_and_transfer_input) =
        bytecode_verifier.is_create2_and_transfer_bytecode_prefix(bytecode_input)
    {
        let x = create2AndTransferParamsCall::abi_decode_raw(create2_and_transfer_input).unwrap();
        if salt != x.salt.as_slice() {
            println!("Salt mismatch: {:?} != {:?}", salt, x.salt);
            return None;
        }
        // We do not need to cross check `owner` here, it will be cross checked against whatever owner is currently set
        // to the final contracts.
        // We do still need to check the input to find out potential constructor param
        let (name, params) = bytecode_verifier.try_parse_bytecode(&x.bytecode)?;
        let salt = FixedBytes::<32>::from_slice(salt);
        let create2_and_transfer_addr =
            compute_create2_address_evm(tx.to().unwrap(), salt, keccak256(&tx.input()[32..]));

        let contract_addr =
            compute_create2_address_evm(create2_and_transfer_addr, salt, keccak256(&x.bytecode));

        return Some((contract_addr, name, params));
    }

    None
}

async fn check_gw_create2_deploy(
    l1_provider: RootProvider,
    bridgehub_addr: &Address,
    transaction: &str,
    bytecode_verifier: &BytecodeVerifier,
) -> Option<(Address, String, Vec<u8>)> {
    let l2_create2_addr = address_from_short_hex("10000");

    let tx_hash: TxHash = transaction.parse().unwrap();

    let tx = l1_provider
        .get_transaction_by_hash(tx_hash)
        .await
        .unwrap()
        .unwrap();

    if tx.to() != Some(*bridgehub_addr) {
        return None;
    }

    let inner_tx = requestL2TransactionDirectCall::abi_decode(tx.input());

    if let Ok(l2_call) = inner_tx {
        if l2_call._request.l2Contract != l2_create2_addr {
            return None;
        }

        let create2_data = create2Call::abi_decode(&l2_call._request.l2Calldata);

        if let Ok(create2_call) = create2_data {
            if create2_call._salt != vec![0u8; 32].as_slice() {
                println!("Salt mismatch: {:?} != {:?}", create2_call._salt, 0);
                return None;
            }

            let addr = compute_create2_address_zk(
                l2_call._request.l2Contract,
                create2_call._salt,
                create2_call._bytecodeHash,
                keccak256(create2_call._input.to_vec()),
            );

            if let Some(file_name) =
                bytecode_verifier.zk_bytecode_hash_to_file(&create2_call._bytecodeHash)
            {
                return Some((addr, file_name.to_string(), create2_call._input.to_vec()));
            }
        }
    }

    None
}
