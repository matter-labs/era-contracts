use alloy::consensus::Transaction;
use alloy::hex::{self, FromHex};
use alloy::primitives::{keccak256, Address, FixedBytes, TxHash, U256};
use alloy::providers::{Provider, RootProvider};
use alloy::sol;
use alloy::sol_types::SolCall;
use anyhow::Context;
use std::collections::HashMap;

use crate::common::logger;

use super::bytecode_verifier::BytecodeVerifier;
use super::compute_create2_address_evm;
use crate::upgrade_verification::constants::{
    EIP1967_IMPLEMENTATION_SLOT, EIP1967_PROXY_ADMIN_SLOT,
};

/// Lookups per transactions-log entry (its tx, then its receipt) before it
/// counts as unfetchable. A hash in a log is expected to exist, so a null or
/// failed answer is usually a flaky or lagging RPC backend: public endpoints
/// return null receipts intermittently.
const LOG_FETCH_ATTEMPTS: u32 = 4;
/// Wait before the second lookup, doubled for each later one (1s, 2s, 4s).
const LOG_FETCH_FIRST_RETRY_MS: u64 = 1_000;

/// Sleep before lookup number `attempt` (1-based retries) of a log entry.
async fn log_fetch_backoff(attempt: u32) {
    let ms = LOG_FETCH_FIRST_RETRY_MS << (attempt - 1);
    tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
}

/// The finding for transactions-log entries still unfetchable after
/// `LOG_FETCH_ATTEMPTS`, whose deployments were therefore never checked:
/// `(is_error, message)`. An error when `strict` (an env with a historical
/// deployment list, where every entry must be accounted for), a warning
/// otherwise, since an append-only log may also hold stale entries of another
/// network. `None` when every entry was fetched.
fn unfetched_finding(unfetched: &[(TxHash, String)], strict: bool) -> Option<(bool, String)> {
    if unfetched.is_empty() {
        return None;
    }
    let list = unfetched
        .iter()
        .map(|(hash, why)| format!("{hash:#x} ({why})"))
        .collect::<Vec<_>>()
        .join(", ");
    Some((
        strict,
        format!(
            "transactions log: {} tx(s) could not be fetched after {LOG_FETCH_ATTEMPTS} attempts, so their deployments were not checked: {list}",
            unfetched.len()
        ),
    ))
}

sol! {
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
    }

    #[sol(rpc)]
    contract L1AssetRouter {
        function legacyBridge() public view returns (address);
        function L1_WETH_TOKEN() public view returns (address);
        function L1_NULLIFIER() public view returns (address);

        function nativeTokenVault() public view returns (address);
    }

    #[sol(rpc)]
    contract L1NativeTokenVault {
        function bridgedTokenBeacon() external view returns (address);
    }

    #[sol(rpc)]
    contract ChainTypeManager {
        function getHyperchain(uint256 _chainId) public view returns (address);
        address public validatorTimelockPostV29;
        function protocolVersion() external view returns (uint256);
        function owner() external view returns (address);
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
        function serverNotifierAddress() external view returns (address);
    }

    #[sol(rpc)]
    contract ZKChain {
        function getProtocolVersion() external view returns (uint256);
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
    pub l1_chain_id: u64,

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
    pub async fn new_v33(l1_rpc: String) -> anyhow::Result<Self> {
        let l1_provider = RootProvider::new_http(l1_rpc.parse().context("invalid L1 RPC URL")?);
        let l1_chain_id = l1_provider
            .get_chain_id()
            .await
            .context("failed to fetch L1 chain id")?;

        Ok(Self {
            l1_provider,
            l1_chain_id,
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
    ///   - reverted on-chain (status != 1)
    ///   - don't target the configured Create2Factory
    ///   - have <32 bytes of input
    ///   - whose bytecode hash no longer matches any contract in
    ///     `AllContractsHashes.json` (stale deploy from a prior regen — the
    ///     natural filter for the append-only file)
    ///
    /// Surfaces three classes of issue via `result`:
    ///   - Unfetchable txs: each lookup is retried (`LOG_FETCH_ATTEMPTS`), and a
    ///     tx or receipt still missing after that is reported (`unfetched_finding`):
    ///     an ERROR when `strict_fetch` (an env with a historical deployment list,
    ///     where every entry must be accounted for), a WARNING otherwise. A
    ///     dropped tx would otherwise hide its deployment from the coverage and
    ///     salt checks.
    ///   - Salt sanity (`expected_salts`, only when `enforce_salts`): every
    ///     recognized deploy whose salt isn't in the env-declared set is a hard
    ///     ERROR. Pass `enforce_salts = false` for a *reference* log — a prior
    ///     regen's already-broadcast deployment, fed in only to enrich the
    ///     address book. Its deploys legitimately carry the salts of that
    ///     regen, and rotating `create2_factory_salt` (which every regen must
    ///     do) would otherwise make every one of them an error.
    ///   - Duplicate metadata: if the same deployed address shows up twice
    ///     with different `(name, ctor_args)`, that's a hard ERROR.
    // Nine positional parameters: the RPC-facing addresses, the salt and fetch
    // policies and the two sinks. Grouping them into a struct would just move the
    // same fields.
    #[allow(clippy::too_many_arguments)]
    pub async fn populate_create2_from_transactions_log(
        &mut self,
        tx_hashes: &[FixedBytes<32>],
        create2_factory: &Address,
        expected_salts: &[FixedBytes<32>],
        enforce_salts: bool,
        strict_fetch: bool,
        bytecode_verifier: &BytecodeVerifier,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    ) {
        let mut unfetched: Vec<(TxHash, String)> = Vec::new();
        let mut reverted = 0_usize;

        for tx_hash in tx_hashes {
            let hash = TxHash::from(*tx_hash);

            let tx = match self.fetch_logged_tx(hash).await {
                Ok(tx) => tx,
                Err(why) => {
                    logger::warn(format!("{hash:#x}: {why}"));
                    unfetched.push((hash, why));
                    continue;
                }
            };

            let Some(to) = tx.to() else {
                continue;
            };

            if to != *create2_factory {
                continue;
            }
            let Some(deployment) =
                parse_l1_create2_deploy_from_input(to, tx.input(), bytecode_verifier)
            else {
                continue;
            };

            match self.fetch_logged_receipt(hash).await {
                Ok(receipt) => {
                    if !receipt.status() {
                        reverted += 1;
                        continue;
                    }
                }
                Err(why) => {
                    logger::warn(format!("{hash:#x}: {why}"));
                    unfetched.push((hash, why));
                    continue;
                }
            }

            if enforce_salts && !expected_salts.contains(&deployment.salt) {
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

        match unfetched_finding(&unfetched, strict_fetch) {
            Some((true, message)) => result.report_error(&message),
            Some((false, message)) => result.report_warn(&message),
            None => {}
        }
        if reverted > 0 {
            logger::warn(format!(
                "transactions.txt: {reverted} tx(s) reverted (status=0) — skipped"
            ));
        }
    }

    /// `eth_getTransactionByHash` for a transactions-log entry, retried (see
    /// `LOG_FETCH_ATTEMPTS`). `Err` carries the last failure, for the report.
    async fn fetch_logged_tx(
        &self,
        hash: TxHash,
    ) -> Result<alloy::rpc::types::Transaction, String> {
        let mut last = String::new();
        for attempt in 0..LOG_FETCH_ATTEMPTS {
            if attempt > 0 {
                log_fetch_backoff(attempt).await;
            }
            match self.l1_provider.get_transaction_by_hash(hash).await {
                Ok(Some(tx)) => return Ok(tx),
                Ok(None) => last = "eth_getTransactionByHash returned null".to_string(),
                Err(err) => last = format!("eth_getTransactionByHash failed: {err}"),
            }
        }
        Err(last)
    }

    /// `eth_getTransactionReceipt` for a transactions-log entry, retried (see
    /// `LOG_FETCH_ATTEMPTS`). `Err` carries the last failure, for the report.
    async fn fetch_logged_receipt(
        &self,
        hash: TxHash,
    ) -> Result<alloy::rpc::types::TransactionReceipt, String> {
        let mut last = String::new();
        for attempt in 0..LOG_FETCH_ATTEMPTS {
            if attempt > 0 {
                log_fetch_backoff(attempt).await;
            }
            match self.l1_provider.get_transaction_receipt(hash).await {
                Ok(Some(receipt)) => return Ok(receipt),
                Ok(None) => last = "eth_getTransactionReceipt returned null".to_string(),
                Err(err) => last = format!("eth_getTransactionReceipt failed: {err}"),
            }
        }
        Err(last)
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

    /// The implementation an EIP-1967 proxy currently points at.
    pub async fn get_proxy_implementation(&self, addr: Address) -> Address {
        let addr_as_bytes = self
            .storage_at(
                &addr,
                &FixedBytes::<32>::from_hex(EIP1967_IMPLEMENTATION_SLOT).unwrap(),
            )
            .await;
        Address::from_slice(&addr_as_bytes[12..])
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

    let bytecode_input = &input[32..];

    // Recognize the wrapper FIRST: its creation code is itself in the hash registry.
    // Parsing it as an ordinary deployment would index the wrapper, losing the inner
    // contract's address and constructor provenance (e.g. Era's RollupDAManager).
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

    let (name, params) = bytecode_verifier.try_parse_bytecode(bytecode_input)?;
    Some(ParsedCreate2Deployment {
        addr: compute_create2_address_evm(to, salt, keccak256(bytecode_input)),
        name,
        params,
        salt,
    })
}
#[cfg(test)]
mod create2_provenance_tests {
    use super::super::bytecode_verifier::ContractHashes;
    use super::*;

    // Synthetic inner code isolates transaction parsing; the real, hash-pinned
    // wrapper stays registered too, which reproduces the shadowing regression.
    const INNER_CODE: &[u8] = &[0x60; 64];
    const INNER_NAME: &str = "test/Inner";

    fn verifier() -> BytecodeVerifier {
        let mut hashes = ContractHashes::init_from_local().unwrap();
        hashes.hashes.push(
            serde_json::from_value(serde_json::json!({
                "contractName": INNER_NAME,
                "evmBytecodeHash": format!("{:#x}", keccak256(INNER_CODE))
            }))
            .unwrap(),
        );
        BytecodeVerifier::from_contract_hashes(hashes)
    }

    fn wrapped_input(
        verifier: &BytecodeVerifier,
        outer_salt: FixedBytes<32>,
        inner_salt: FixedBytes<32>,
        inner: Vec<u8>,
    ) -> Vec<u8> {
        let mut input = outer_salt.to_vec();
        input.extend(verifier.get_create2_and_transfer_bytecode());
        input.extend(
            create2AndTransferParamsCall {
                bytecode: inner.into(),
                salt: inner_salt,
                owner: Address::ZERO,
            }
            .abi_encode()[4..]
                .iter()
                .copied(),
        );
        input
    }

    #[test]
    fn registered_wrapper_indexes_inner_address_and_constructor_params() {
        let verifier = verifier();
        let salt = FixedBytes::<32>::ZERO;
        let factory = Address::ZERO;
        for params in [vec![], vec![0x42; 32]] {
            let inner = [INNER_CODE, params.as_slice()].concat();
            let input = wrapped_input(&verifier, salt, salt, inner.clone());
            let wrapper = compute_create2_address_evm(factory, salt, keccak256(&input[32..]));
            let parsed = parse_l1_create2_deploy_from_input(factory, &input, &verifier).unwrap();
            assert_eq!(parsed.name, INNER_NAME);
            assert_eq!(
                parsed.addr,
                compute_create2_address_evm(wrapper, salt, keccak256(&inner))
            );
            assert_ne!(parsed.addr, wrapper);
            assert_eq!(parsed.params, params);
            assert_eq!(parsed.salt, salt);
        }
    }

    #[test]
    fn malformed_wrapper_does_not_fall_back_to_outer_deployment() {
        let verifier = verifier();
        let salt = FixedBytes::<32>::ZERO;
        let wrong_salt = FixedBytes::<32>::repeat_byte(1);
        let input = wrapped_input(&verifier, salt, wrong_salt, INNER_CODE.to_vec());
        assert!(parse_l1_create2_deploy_from_input(Address::ZERO, &input, &verifier).is_none());
        let mut input = salt.to_vec();
        input.extend(verifier.get_create2_and_transfer_bytecode());
        assert!(parse_l1_create2_deploy_from_input(Address::ZERO, &input, &verifier).is_none());
        let input = wrapped_input(&verifier, salt, salt, vec![0xff]);
        assert!(parse_l1_create2_deploy_from_input(Address::ZERO, &input, &verifier).is_none());
    }

    #[test]
    fn direct_create2_still_preserves_constructor_params() {
        let verifier = verifier();
        let salt = FixedBytes::<32>::ZERO;
        let params = vec![0x42; 32];
        let init = [INNER_CODE, params.as_slice()].concat();
        let input = [salt.as_slice(), init.as_slice()].concat();
        let parsed = parse_l1_create2_deploy_from_input(Address::ZERO, &input, &verifier).unwrap();
        assert_eq!(parsed.name, INNER_NAME);
        assert_eq!(parsed.params, params);
        assert_eq!(
            parsed.addr,
            compute_create2_address_evm(Address::ZERO, salt, keccak256(&init))
        );
        assert!(parse_l1_create2_deploy_from_input(Address::ZERO, &[0; 31], &verifier).is_none());
    }
}

#[cfg(test)]
mod unfetched_tests {
    use super::{unfetched_finding, TxHash};

    /// Entries still unfetchable after the retries are reported with their hashes: an error
    /// for an env with a historical list (strict), a warning otherwise, nothing when all fetched.
    #[test]
    fn unfetched_log_entries_are_reported_and_strict_envs_fail() {
        assert!(unfetched_finding(&[], true).is_none());

        let unfetched = vec![
            (
                TxHash::repeat_byte(0x8c),
                "eth_getTransactionReceipt returned null".to_string(),
            ),
            (
                TxHash::repeat_byte(0x43),
                "eth_getTransactionByHash failed: 429".to_string(),
            ),
        ];
        let (is_error, message) = unfetched_finding(&unfetched, true).unwrap();
        assert!(is_error);
        assert!(
            message.contains("2 tx(s) could not be fetched"),
            "{message}"
        );
        for (hash, why) in &unfetched {
            assert!(message.contains(&format!("{hash:#x} ({why})")), "{message}");
        }

        let (is_error, _) = unfetched_finding(&unfetched, false).unwrap();
        assert!(!is_error);
    }
}
