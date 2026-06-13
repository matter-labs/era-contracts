use alloy::consensus::Transaction;
use alloy::hex::{self, FromHex};
use alloy::primitives::{keccak256, Address, FixedBytes, TxHash, U256};
use alloy::providers::{Provider, RootProvider};
use alloy::sol;
use alloy::sol_types::SolCall;
use anyhow::Context;
use std::collections::HashMap;
use Bridgehub::requestL2TransactionDirectCall;

use crate::common::logger;

use super::bytecode_verifier::BytecodeVerifier;
use super::{compute_create2_address_evm, compute_create2_address_zk};
use crate::upgrade_verification::constants::{
    EIP1967_PROXY_ADMIN_SLOT, L2_CREATE2_FACTORY_ADDR, ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR,
};

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
        function settlementLayer(uint256 _chainId) external view returns (uint256);
        function assetRouter() external view returns (address);
        function l1CtmDeployer() external view returns (address);
        function messageRoot() external view returns (address);
        function chainAssetHandler() external view returns (address);
        function getZKChain(uint256 _chainId) external view returns (address chainAddress);
        function baseToken(uint256 _chainId) external view returns (address);
        function requestL2TransactionDirect(
            L2TransactionRequestDirect calldata _request
        ) external payable returns (bytes32 canonicalTxHash);
    }

    #[sol(rpc)]
    contract L1AssetRouter {
        function legacyBridge() public view returns (address);
        function L1_WETH_TOKEN() public view returns (address);
        function L1_NULLIFIER() public view returns (address);
        function ERA_CHAIN_ID() public view returns (uint256);

        function nativeTokenVault() public view returns (address);
    }

    #[sol(rpc)]
    contract ChainTypeManager {
        function getHyperchain(uint256 _chainId) public view returns (address);
        address public validatorTimelockPostV29;
        function protocolVersion() external view returns (uint256);
        function isZKsyncOS() external view returns (bool);
        function owner() external view returns (address);
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
    }

    #[sol(rpc)]
    contract ZKChain {
        function getProtocolVersion() external view returns (uint256);
    }

    #[sol(rpc)]
    contract ZKChainFeeParams {
        function getPriorityTxMaxGasLimit() external view returns (uint256);
    }

    /// Minimal `Ownable` view — usable against any contract that exposes a
    /// public `owner()` getter (TransparentUpgradeableProxy admins, plain
    /// Ownable proxies, etc.).
    #[sol(rpc)]
    contract Ownable {
        function owner() external view returns (address);
    }

    /// Minimal `Ownable2Step` view for contracts whose pending owner is a
    /// pre-governance invariant.
    #[sol(rpc)]
    contract Ownable2Step {
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
    }

    #[sol(rpc)]
    contract L1AssetTracker {
        function BRIDGE_HUB() external view returns (address);
        function chainAssetHandler() external view returns (address);
    }

    #[sol(rpc)]
    contract ChainRegistrationSender {
        function BRIDGE_HUB() external view returns (address);
    }

    #[sol(rpc)]
    contract ValidatorTimelock {
        function executionDelay() external view returns (uint32);
    }

    function create2AndTransferParams(bytes memory bytecode, bytes32 salt, address owner);

    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address);
}

pub struct NetworkVerifier {
    pub l1_provider: RootProvider,
    pub era_chain_id: u64,
    pub l1_chain_id: u64,
    pub gateway_chain_id: u64,
    pub gw_provider: RootProvider,

    // todo: maybe merge into one struct.
    pub create2_known_bytecodes: HashMap<Address, String>,
    pub create2_constructor_params: HashMap<Address, Vec<u8>>,
}

struct ParsedCreate2Deployment {
    addr: Address,
    name: String,
    params: Vec<u8>,
    salt: FixedBytes<32>,
}

impl NetworkVerifier {
    pub async fn new_v31(
        l1_rpc: String,
        gw_rpc: String,
        era_chain_id: u64,
    ) -> anyhow::Result<Self> {
        let l1_provider = RootProvider::new_http(l1_rpc.parse().context("invalid L1 RPC URL")?);
        let l1_chain_id = l1_provider
            .get_chain_id()
            .await
            .context("failed to fetch L1 chain id")?;
        let gw_provider =
            RootProvider::new_http(gw_rpc.parse().context("invalid gateway RPC URL")?);
        let gateway_chain_id = gw_provider
            .get_chain_id()
            .await
            .context("failed to fetch gateway chain id")?;

        Ok(Self {
            l1_provider,
            era_chain_id,
            l1_chain_id,
            gateway_chain_id,
            gw_provider,
            create2_constructor_params: HashMap::new(),
            create2_known_bytecodes: HashMap::new(),
        })
    }

    /// L1-only constructor for narrow verifiers that only need Ethereum
    /// transaction provenance. The gateway provider is pointed at the same RPC
    /// so existing struct users can stay non-optional.
    pub async fn new_l1_only(l1_rpc: String) -> anyhow::Result<Self> {
        let l1_provider = RootProvider::new_http(l1_rpc.parse().context("invalid L1 RPC URL")?);
        let l1_chain_id = l1_provider
            .get_chain_id()
            .await
            .context("failed to fetch L1 chain id")?;

        Ok(Self {
            l1_provider: l1_provider.clone(),
            era_chain_id: 0,
            l1_chain_id,
            gateway_chain_id: l1_chain_id,
            gw_provider: l1_provider,
            create2_constructor_params: HashMap::new(),
            create2_known_bytecodes: HashMap::new(),
        })
    }

    /// Walk a `transactions.txt`-style hash list and turn each successful
    /// CREATE2-factory tx into a `(deployed address → contract file +
    /// constructor args)` entry.
    ///
    /// `transactions.txt` is append-only across regens, so we silently skip
    /// txs that:
    ///   - aren't on the RPC (wrong network, or stale-file warning)
    ///   - reverted on-chain (status != 1)
    ///   - don't target the configured Create2Factory
    ///   - have <32 bytes of input
    ///   - whose bytecode hash no longer matches any contract in
    ///     `AllContractsHashes.json` (stale deploy from a prior regen — the
    ///     natural filter for the append-only file)
    ///
    /// Surfaces two classes of issue via `result`:
    ///   - Salt sanity (`expected_salts`): every recognized deploy whose salt
    ///     isn't in the env-declared set is a hard ERROR.
    ///   - Duplicate metadata: if the same deployed address shows up twice
    ///     with different `(name, ctor_args)`, that's a hard ERROR.
    pub async fn populate_create2_from_transactions_log(
        &mut self,
        tx_hashes: &[FixedBytes<32>],
        create2_factory: &Address,
        bridgehub_addr: &Address,
        expected_salts: &[FixedBytes<32>],
        bytecode_verifier: &BytecodeVerifier,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    ) {
        let mut fetch_failures = 0_usize;
        let mut reverted = 0_usize;
        let mut parsed_gateway_deployments = 0_usize;

        for tx_hash in tx_hashes {
            let hash = TxHash::from(*tx_hash);

            let tx = match self.l1_provider.get_transaction_by_hash(hash).await {
                Ok(Some(tx)) => tx,
                Ok(None) => {
                    fetch_failures += 1;
                    continue;
                }
                Err(err) => {
                    logger::warn(format!("eth_getTransactionByHash({hash:#x}) failed: {err}"));
                    fetch_failures += 1;
                    continue;
                }
            };

            let Some(to) = tx.to() else {
                continue;
            };

            let deployment = if to == *create2_factory {
                parse_l1_create2_deploy_from_input(to, tx.input(), bytecode_verifier)
            } else if to == *bridgehub_addr {
                check_gw_create2_deploy_from_input(
                    to,
                    tx.input(),
                    bridgehub_addr,
                    bytecode_verifier,
                )
            } else {
                None
            };
            let Some(deployment) = deployment else {
                continue;
            };

            match self.l1_provider.get_transaction_receipt(hash).await {
                Ok(Some(receipt)) => {
                    if !receipt.status() {
                        reverted += 1;
                        continue;
                    }
                }
                Ok(None) => {
                    logger::warn(format!(
                        "eth_getTransactionReceipt({hash:#x}) returned null"
                    ));
                    fetch_failures += 1;
                    continue;
                }
                Err(err) => {
                    logger::warn(format!(
                        "eth_getTransactionReceipt({hash:#x}) failed: {err}"
                    ));
                    fetch_failures += 1;
                    continue;
                }
            }

            if to == *bridgehub_addr {
                parsed_gateway_deployments += 1;
                if !expected_salts.contains(&deployment.salt) {
                    result.report_error(&format!(
                        "Gateway CREATE2 deployment of {} at {} (tx {hash:#x}) used salt {} \
                         which is not in the env-declared salt set",
                        deployment.name, deployment.addr, deployment.salt
                    ));
                }
            } else if !expected_salts.contains(&deployment.salt) {
                // Salt sanity: only enforced after recognition, so non-deploy tx
                // first-32 bytes (which aren't salts at all) don't trigger errors.
                // Hard ERROR per offending deploy — `ensure_success` rejects the
                // run, but the entry is still inserted into the map below so
                // downstream address-book lookups in `expect_create2_params` are
                // unaffected.
                result.report_error(&format!(
                    "Deployment of {} at {} (tx {hash:#x}) used salt {} \
                     which is not in the env-declared salt set",
                    deployment.name, deployment.addr, deployment.salt
                ));
            }

            self.insert_create2_deployment(deployment, result);
        }

        if fetch_failures > 0 {
            logger::warn(format!(
                "transactions.txt: {fetch_failures} tx(s) not found on the RPC — wrong network, or stale file?"
            ));
        }
        if reverted > 0 {
            logger::warn(format!(
                "transactions.txt: {reverted} tx(s) reverted (status=0) — skipped"
            ));
        }
        if parsed_gateway_deployments > 0 {
            logger::info(format!(
                "transactions.txt: loaded {parsed_gateway_deployments} Gateway L1→L2 CREATE2 deployment tx(s)"
            ));
        }
    }

    fn insert_create2_deployment(
        &mut self,
        deployment: ParsedCreate2Deployment,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    ) {
        let ParsedCreate2Deployment {
            addr,
            name,
            params,
            salt: _,
        } = deployment;

        // Duplicate detection: same address showing up twice with mismatched
        // metadata is a hard error.
        if let Some(existing_name) = self.create2_known_bytecodes.get(&addr) {
            if existing_name != &name {
                result.report_error(&format!(
                    "Duplicate CREATE2 deployment at {addr}: name conflict — \
                     existing={existing_name}, new={name}"
                ));
                return;
            }
            if let Some(existing_params) = self.create2_constructor_params.get(&addr) {
                if existing_params != &params {
                    result.report_error(&format!(
                        "Duplicate CREATE2 deployment at {addr} ({name}): ctor args differ. \
                         existing=0x{}, new=0x{}",
                        hex::encode(existing_params),
                        hex::encode(&params),
                    ));
                    return;
                }
            }
            // Same address, same metadata — idempotent re-deploy. Skip.
            return;
        }

        self.create2_known_bytecodes.insert(addr, name);
        self.create2_constructor_params.insert(addr, params);
    }

    pub fn get_gateway_chain_id(&self) -> u64 {
        self.gateway_chain_id
    }

    pub async fn get_bytecode_hash_at(&self, address: &Address) -> FixedBytes<32> {
        let code = self.l1_provider.get_code_at(*address).await.unwrap();
        if code.is_empty() {
            // If address has no bytecode - we return formal 0s.
            FixedBytes::ZERO
        } else {
            keccak256(&code)
        }
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

    pub async fn try_get_all_zk_chain_ids(
        &self,
        bridgehub_addr: Address,
    ) -> anyhow::Result<Vec<U256>> {
        let bridgehub = Bridgehub::new(bridgehub_addr, self.l1_provider.clone());
        bridgehub
            .getAllZKChainChainIDs()
            .call()
            .await
            .context("failed to fetch registered ZK chain ids")
    }

    pub async fn try_get_chain_type_manager_from_bridgehub(
        &self,
        bridgehub_addr: Address,
        chain_id: U256,
    ) -> anyhow::Result<Address> {
        let bridgehub = Bridgehub::new(bridgehub_addr, self.l1_provider.clone());
        bridgehub
            .chainTypeManager(chain_id)
            .call()
            .await
            .context("failed to fetch chain type manager from Bridgehub")
    }

    pub async fn try_get_chain_protocol_version(
        &self,
        chain_diamond_addr: Address,
    ) -> anyhow::Result<U256> {
        let chain = ZKChain::new(chain_diamond_addr, self.l1_provider.clone());
        chain
            .getProtocolVersion()
            .call()
            .await
            .context("failed to fetch ZK chain protocolVersion")
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

    pub async fn try_get_gateway_proxy_admin(&self, addr: Address) -> anyhow::Result<Address> {
        let slot = FixedBytes::<32>::from_hex(EIP1967_PROXY_ADMIN_SLOT)
            .context("invalid EIP-1967 admin slot literal")?;
        let storage = self
            .gw_provider
            .get_storage_at(addr, U256::from_be_bytes(slot.0))
            .await
            .with_context(|| format!("failed to read Gateway proxy admin slot for {addr}"))?;

        let bytes = FixedBytes::<32>::from_slice(&storage.to_be_bytes_vec());
        Ok(Address::from_slice(&bytes[12..]))
    }
}

/// Fetches the `transaction` and tries to parse it as a CREATE2 deployment
/// transaction.
/// If successful, it returns a tuple of three items: the address of the deployed contract,
/// the path to the contract and its constructor params.
///
/// Same logic as `check_create2_deploy` but operates on raw `(to, input)`
/// instead of a tx hash → useful for replaying the bundle that
/// `dev execute-safe --out` writes (the bundle log already carries the raw
/// data so we don't need an `eth_getTransactionByHash` round-trip).
fn parse_l1_create2_deploy_from_input(
    to: Address,
    input: &[u8],
    bytecode_verifier: &BytecodeVerifier,
) -> Option<ParsedCreate2Deployment> {
    if input.len() < 32 {
        return None;
    }

    // There are two types of CREATE2 deployments that were used:
    // - Usual, using CREATE2Factory directly.
    // - By using the `Create2AndTransfer` contract.
    // We will try both here.

    let salt = &input[0..32];
    let salt = FixedBytes::<32>::from_slice(salt);

    if let Some((name, params)) = bytecode_verifier.try_parse_bytecode(&input[32..]) {
        let addr = compute_create2_address_evm(to, salt, keccak256(&input[32..]));
        return Some(ParsedCreate2Deployment {
            addr,
            name,
            params,
            salt,
        });
    };

    let bytecode_input = &input[32..];

    // Okay, this may be the `Create2AndTransfer` method.
    if let Some(create2_and_transfer_input) =
        bytecode_verifier.is_create2_and_transfer_bytecode_prefix(bytecode_input)
    {
        let x = create2AndTransferParamsCall::abi_decode_raw(create2_and_transfer_input).ok()?;
        if salt != x.salt {
            return None;
        }
        // We do not need to cross check `owner` here, it will be cross checked against whatever owner is currently set
        // to the final contracts.
        // We do still need to check the input to find out potential constructor param
        let (name, params) = bytecode_verifier.try_parse_bytecode(&x.bytecode)?;
        let create2_and_transfer_addr =
            compute_create2_address_evm(to, salt, keccak256(&input[32..]));

        let contract_addr =
            compute_create2_address_evm(create2_and_transfer_addr, salt, keccak256(&x.bytecode));

        return Some(ParsedCreate2Deployment {
            addr: contract_addr,
            name,
            params,
            salt,
        });
    }

    None
}

fn check_gw_create2_deploy_from_input(
    to: Address,
    input: &[u8],
    bridgehub_addr: &Address,
    bytecode_verifier: &BytecodeVerifier,
) -> Option<ParsedCreate2Deployment> {
    if to != *bridgehub_addr {
        return None;
    }

    let l2_call = requestL2TransactionDirectCall::abi_decode(input).ok()?;
    let l2_contract = l2_call._request.l2Contract;
    let l2_calldata = l2_call._request.l2Calldata;

    if l2_contract == ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR {
        // ZKsync OS uses the standard EVM deterministic factory whose calldata
        // is `bytes32 salt || initCode`.
        let raw = l2_calldata.as_ref();
        if raw.len() < 32 {
            return None;
        }
        let salt = FixedBytes::<32>::from_slice(&raw[..32]);
        let init_code = &raw[32..];
        let (name, params) = bytecode_verifier.try_parse_bytecode(init_code)?;
        let addr = compute_create2_address_evm(l2_contract, salt, keccak256(init_code));
        return Some(ParsedCreate2Deployment {
            addr,
            name,
            params,
            salt,
        });
    }

    if l2_contract == L2_CREATE2_FACTORY_ADDR {
        // Era gateway deployments still call the ZKsync create2 system
        // factory: create2(salt, bytecodeHash, constructorInput).
        let create2_call = create2Call::abi_decode(&l2_calldata).ok()?;
        let salt = create2_call._salt;
        let addr = compute_create2_address_zk(
            l2_contract,
            salt,
            create2_call._bytecodeHash,
            keccak256(&create2_call._input),
        );
        let file_name = bytecode_verifier.zk_bytecode_hash_to_file(&create2_call._bytecodeHash)?;
        return Some(ParsedCreate2Deployment {
            addr,
            name: file_name.to_string(),
            params: create2_call._input.to_vec(),
            salt,
        });
    }

    None
}
