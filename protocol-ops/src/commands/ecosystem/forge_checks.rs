//! Built-in checks of a `forge-script` upgrade (`builtin_checks = true` in its `upgrade.toml`).
//! They read `ecosystem.toml` in the layout `DefaultCTMUpgrade.saveOutput` writes and are the
//! same for every upgrade of an Era CTM; what one upgrade must contain is checked by its own
//! Foundry tests, which the files written here feed.
//!
//! - publication (fork and chain): every factory dep of the L2 upgrade transaction is
//!   published in the BytecodesSupplier, every output address has code, and the output's
//!   supplier is the CTM's;
//! - provenance (fork): every deployer transaction is a CREATE2 deployment through the env's
//!   factory of a bytecode in `AllContractsHashes.json`, or a publication to the supplier;
//!   one salt; every deployment is an output address, and every output address without code at
//!   the fork block is deployed exactly once. Writes `deployments.json`
//!   (`{salt, deployments: [{contract, address, args}]}`); whether the salt and the
//!   constructor args are the right ones is the upgrade's knowledge, checked in Foundry;
//! - the replay (fork): the ServerNotifier upgrade and governance stages 0–2, each sent as its
//!   real sender, with the CTM checked after each; the reference chain's upgrade timestamp,
//!   drain and upgrade; a new test chain; the reference chain's last execute transaction. It
//!   assumes a minor-version upgrade whose upgrade contract refuses a chain with unexecuted
//!   batches (v31's and v34's do);
//! - `fork_tests`: the upgrade's Foundry test files, on the replayed fork, with its exports.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Display;
use std::fs;
use std::path::Path;
use std::process::Command;

use alloy::consensus::Transaction as _;
use alloy::eips::BlockNumberOrTag;
use alloy::network::TransactionBuilder;
use alloy::primitives::{b256, keccak256, Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::rpc::types::{Filter, TransactionRequest};
use alloy::sol_types::{SolCall, SolError, SolValue};
use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::common::abi::chain_admin_ownable::IChainAdminOwnable;
use crate::common::abi::upgrade_errors::{
    DeadlineNotYetPassed, NotAllBatchesExecuted, PreviousUpgradeNotFinalized,
};
use crate::common::abi::{
    BridgehubAbi, ChainAdminOwnableAbi, IBytecodesSupplierPublish, IChainAdminAbi,
    IChainAssetHandlerAbi, IChainTypeManagerAbi, IChainTypeManagerExt, IGovernanceUpgradeTimer,
    IOwnable, IPerChainRoles, IProxyAdmin, IServerNotifier, ValidatorTimelockAbi, ZkChainAbi,
};
use crate::common::anvil::{evm_increase_time_and_mine, send_impersonated_tx, set_balance};
use crate::common::env_config::EnvConfig;
use crate::common::ethereum::{get_read_provider, AlloyProvider};
use crate::common::governance_calls::{decode_calls, GovernanceCall};
use crate::common::l1_contracts::{
    execution_revert_data, resolve_bytecodes_supplier, resolve_is_testnet_verifier,
    resolve_is_zksync_os, reverted_without_data,
};
use crate::common::upgrade_descriptor::ForkTest;
use crate::common::{logger, paths};
use crate::upgrade_verification::constants::EIP1967_PROXY_ADMIN_SLOT;
use crate::upgrade_verification::verifiers::VerificationResult;
use crate::upgrade_verification::versions::v31::elements::set_new_version_upgrade::{
    upgradeCall, BytecodesSupplier, DiamondCutData,
};
use crate::upgrade_verification::versions::v31::utils::{
    bytecode_verifier::BytecodeVerifier, compute_create2_address_evm,
};

/// The identified deployments, written into the run's work dir for the fork tests.
pub(crate) const DEPLOYMENTS_FILE: &str = "deployments.json";

/// What the built-ins read from `ecosystem.toml`.
#[derive(Debug, Deserialize)]
pub(crate) struct UpgradeOutput {
    /// `abi.encode(DiamondCutData)`: the cut chains upgrade with.
    pub chain_upgrade_diamond_cut: Bytes,
    pub contracts_config: ContractsConfig,
    pub state_transition: BTreeMap<String, Address>,
    pub deployed_addresses: BTreeMap<String, Address>,
    pub governance_calls: GovernanceCalls,
    pub ctm_admin_calls: CtmAdminCalls,
    pub test_upgrade_calls: TestUpgradeCalls,
    /// The L2 upgrade transaction's factory deps, decoded from the cut.
    #[serde(skip)]
    pub factory_deps: Vec<B256>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ContractsConfig {
    pub old_protocol_version: u64,
    pub new_protocol_version: u64,
    /// `abi.encode(DiamondCutData)` for new chains.
    pub diamond_cut_data: Bytes,
    pub force_deployments_data: Bytes,
    pub governance_upgrade_timer_initial_delay: u64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GovernanceCalls {
    #[serde(deserialize_with = "calls")]
    pub stage0_calls: Vec<GovernanceCall>,
    #[serde(deserialize_with = "calls")]
    pub stage1_calls: Vec<GovernanceCall>,
    #[serde(deserialize_with = "calls")]
    pub stage2_calls: Vec<GovernanceCall>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct CtmAdminCalls {
    pub chain_admin: Address,
    pub chain_admin_owner: Address,
    #[serde(deserialize_with = "calls")]
    pub server_notifier_upgrade: Vec<GovernanceCall>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TestUpgradeCalls {
    #[serde(deserialize_with = "calls")]
    pub test_upgrade_chain: Vec<GovernanceCall>,
    pub test_upgrade_chain_caller: Address,
    #[serde(deserialize_with = "calls")]
    pub test_create_chain: Vec<GovernanceCall>,
    pub test_create_chain_caller: Address,
}

/// `abi.encode(Call[])` as hex.
fn calls<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<GovernanceCall>, D::Error> {
    let hex = String::deserialize(deserializer)?;
    decode_calls(&hex).map_err(|error| serde::de::Error::custom(format!("{error:#}")))
}

impl UpgradeOutput {
    pub(crate) fn read(path: &Path) -> anyhow::Result<Self> {
        let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        Self::parse(&raw).with_context(|| {
            format!(
                "{}: not in DefaultCTMUpgrade.saveOutput's layout",
                path.display()
            )
        })
    }

    fn parse(raw: &str) -> anyhow::Result<Self> {
        let mut output: Self = toml::from_str(raw)?;
        let cut = DiamondCutData::abi_decode(&output.chain_upgrade_diamond_cut)
            .context("chain_upgrade_diamond_cut is not abi.encode(DiamondCutData)")?;
        let upgrade = upgradeCall::abi_decode(&cut.initCalldata)
            .context("chain_upgrade_diamond_cut's initCalldata is not upgrade(ProposedUpgrade)")?;
        let tx = upgrade._proposedUpgrade.l2ProtocolUpgradeTx;
        output.factory_deps = tx.factoryDeps.iter().map(|dep| B256::from(*dep)).collect();
        Ok(output)
    }

    /// `state_transition.<key>`, which must be set and non-zero.
    pub(crate) fn state_transition_address(&self, key: &str) -> anyhow::Result<Address> {
        self.state_transition
            .get(key)
            .copied()
            .filter(|address| !address.is_zero())
            .ok_or_else(|| anyhow::anyhow!("state_transition.{key} is missing or zero"))
    }

    /// Every non-zero address of `[state_transition]` and `[deployed_addresses]`, with the
    /// keys that name it.
    pub(crate) fn output_addresses(&self) -> BTreeMap<Address, String> {
        let mut out: BTreeMap<Address, String> = BTreeMap::new();
        let tables = [
            ("state_transition", &self.state_transition),
            ("deployed_addresses", &self.deployed_addresses),
        ];
        for (table, entries) in tables {
            for (key, address) in entries.iter().filter(|(_, address)| !address.is_zero()) {
                let name = format!("{table}.{key}");
                out.entry(*address)
                    .and_modify(|names| *names = format!("{names} / {name}"))
                    .or_insert(name);
            }
        }
        out
    }
}

/// A checker's findings, printed the way PUVT prints its own; `finish` fails listing every
/// error.
#[derive(Default)]
pub(crate) struct Report {
    result: VerificationResult,
    errors: Vec<String>,
}

impl Report {
    pub(crate) fn ok(&self, what: impl AsRef<str>) {
        self.result.report_ok(what.as_ref());
    }

    pub(crate) fn error(&mut self, what: impl Into<String>) {
        let what = what.into();
        self.result.report_error(&what);
        self.errors.push(what);
    }

    pub(crate) fn equal<T: PartialEq + Display>(&mut self, what: &str, got: T, want: T) {
        if got == want {
            self.ok(what);
        } else {
            self.error(format!("{what}: expected {want}, got {got}"));
        }
    }

    pub(crate) fn finish(self) -> anyhow::Result<()> {
        anyhow::ensure!(self.errors.is_empty(), "{}", self.errors.join("; "));
        Ok(())
    }
}

/// Every factory dep of the L2 upgrade transaction is published, every output address has
/// code, and the output's supplier is the CTM's. Read-only, so safe against a real chain.
pub(crate) async fn check_publication(rpc_url: &str, output: &UpgradeOutput) -> anyhow::Result<()> {
    let provider = get_read_provider(rpc_url)?;
    let mut report = Report::default();
    let supplier = output.state_transition_address("bytecodes_supplier_addr")?;
    let ctm = output.state_transition_address("chain_type_manager_proxy")?;
    // A ZKsync OS CTM publishes EVM bytecodes, into `evmPublishingBlock`.
    anyhow::ensure!(
        !resolve_is_zksync_os(rpc_url, ctm).await?,
        "{ctm} is a ZKsync OS CTM: the built-in checks support Era CTMs only"
    );

    let bytecodes_supplier = BytecodesSupplier::new(supplier, provider.clone());
    let mut unpublished = 0;
    for dep in &output.factory_deps {
        let block = bytecodes_supplier
            .publishingBlock(*dep)
            .call()
            .await
            .with_context(|| format!("BytecodesSupplier({supplier}).publishingBlock({dep})"))?;
        if block.is_zero() {
            unpublished += 1;
            report.error(format!("factory dep {dep} is not published on {supplier}"));
        }
    }
    if output.factory_deps.is_empty() {
        report.error("the L2 upgrade transaction has no factory deps");
    } else if unpublished == 0 {
        report.ok(format!(
            "all {} factory deps of the L2 upgrade transaction are published on {supplier}",
            output.factory_deps.len()
        ));
    }

    let addresses = output.output_addresses();
    let mut without_code = 0;
    for (address, names) in &addresses {
        let code = provider
            .get_code_at(*address)
            .await
            .with_context(|| format!("eth_getCode({address})"))?;
        if code.is_empty() {
            without_code += 1;
            report.error(format!("{names} {address} has no code"));
        }
    }
    if without_code == 0 {
        report.ok(format!(
            "all {} output addresses have code",
            addresses.len()
        ));
    }

    report.equal(
        "state_transition.bytecodes_supplier_addr = the CTM's L1_BYTECODES_SUPPLIER()",
        supplier,
        resolve_bytecodes_supplier(rpc_url, ctm).await?,
    );
    report.finish()
}

/// A deployer transaction as `prepare/*.safe.json` holds it.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DeployerTx {
    pub to: Address,
    /// Decimal or `0x` hex.
    pub value: String,
    pub data: Bytes,
}

/// One identified CREATE2 deployment.
#[derive(Debug, Serialize)]
pub(crate) struct Deployment {
    /// `AllContractsHashes.json`'s name, e.g. `l1-contracts/AdminFacet`.
    pub contract: String,
    pub address: Address,
    /// The constructor arguments after the bytecode.
    pub args: Bytes,
}

/// `deployments.json`.
#[derive(Debug, Serialize)]
pub(crate) struct Deployments {
    /// `None` when nothing is deployed.
    pub salt: Option<B256>,
    pub deployments: Vec<Deployment>,
}

/// Provenance of the deployer transactions on the fork the bundle was replayed on, through
/// `factory` (`permanent-values/<env>.toml`'s `create2_factory_addr`). Writes
/// `deployments.json` into `work_dir`.
pub(crate) async fn check_provenance(
    rpc_url: &str,
    output: &UpgradeOutput,
    factory: Address,
    txs: &[DeployerTx],
    fork_block: u64,
    work_dir: &Path,
) -> anyhow::Result<()> {
    let provider = get_read_provider(rpc_url)?;
    let supplier = output.state_transition_address("bytecodes_supplier_addr")?;
    let addresses = output.output_addresses();
    let mut undeployed = BTreeSet::new();
    for address in addresses.keys() {
        let code = provider
            .get_code_at(*address)
            .block_id(fork_block.into())
            .await
            .with_context(|| format!("eth_getCode({address}) at block {fork_block}"))?;
        if code.is_empty() {
            undeployed.insert(*address);
        }
    }
    let hashes = BytecodeVerifier::init_from_local()?;
    let mut report = Report::default();
    let found = identify_deployments(
        txs,
        factory,
        supplier,
        &addresses,
        &undeployed,
        &hashes,
        &mut report,
    );
    fs::create_dir_all(work_dir)?;
    let path = work_dir.join(DEPLOYMENTS_FILE);
    fs::write(&path, serde_json::to_string_pretty(&found)? + "\n")
        .with_context(|| format!("write {}", path.display()))?;
    report.ok(format!("deployments written to {}", path.display()));
    report.finish()
}

/// The provenance rules on their own (no RPC). `undeployed`: the output addresses that had
/// no code at the fork block.
fn identify_deployments(
    txs: &[DeployerTx],
    factory: Address,
    supplier: Address,
    output: &BTreeMap<Address, String>,
    undeployed: &BTreeSet<Address>,
    hashes: &BytecodeVerifier,
    report: &mut Report,
) -> Deployments {
    let publish = [
        IBytecodesSupplierPublish::publishEraBytecodeCall::SELECTOR,
        IBytecodesSupplierPublish::publishEraBytecodesCall::SELECTOR,
    ];
    let errors_before = report.errors.len();
    let mut salt: Option<B256> = None;
    let mut deployments: Vec<Deployment> = Vec::new();
    let mut publications = 0;
    for (index, tx) in txs.iter().enumerate() {
        let label = format!("deployer tx #{index} (to {})", tx.to);
        if !tx.value.parse::<U256>().is_ok_and(|value| value.is_zero()) {
            report.error(format!("{label} sends value {}", tx.value));
        }
        if tx.to == supplier && tx.data.len() >= 4 && publish.iter().any(|s| tx.data[..4] == *s) {
            publications += 1;
            continue;
        }
        if tx.to != factory || tx.data.len() < 32 {
            report.error(format!(
                "{label} is neither a CREATE2 deployment through {factory} nor a publication to {supplier}"
            ));
            continue;
        }
        let (tx_salt, init_code) = tx.data.split_at(32);
        let tx_salt = B256::from_slice(tx_salt);
        match salt {
            None => salt = Some(tx_salt),
            Some(first) if first != tx_salt => {
                report.error(format!(
                    "{label} uses salt {tx_salt}, an earlier one {first}"
                ));
            }
            Some(_) => {}
        }
        let address = compute_create2_address_evm(factory, tx_salt, keccak256(init_code));
        let Some((contract, args)) = hashes.try_parse_bytecode(init_code) else {
            report.error(format!(
                "{label}: the init code for {address} is no bytecode of AllContractsHashes.json \
                 followed by constructor args"
            ));
            continue;
        };
        if !contract.starts_with("l1-contracts/") && !contract.starts_with("da-contracts/") {
            report.error(format!("{label} deploys {contract}, not an L1 contract"));
        } else if !output.contains_key(&address) {
            report.error(format!(
                "{label} deploys {contract} at {address}, which the output doesn't list"
            ));
        } else if deployments.iter().any(|known| known.address == address) {
            report.error(format!("{label} deploys {address} a second time"));
        } else {
            deployments.push(Deployment {
                contract,
                address,
                args: args.into(),
            });
        }
    }
    for address in undeployed {
        if !deployments.iter().any(|known| known.address == *address) {
            report.error(format!(
                "{} {address} had no code at the fork block, and no deployer transaction deploys it",
                output[address]
            ));
        }
    }
    if report.errors.len() == errors_before {
        report.ok(format!(
            "{} CREATE2 deployments identified and {publications} publications, one salt",
            deployments.len()
        ));
    }
    Deployments { salt, deployments }
}

// ─── The replay ──────────────────────────────────────────────────────────────────

/// The reference chain's last execute transaction's input, for the first-batch fork tests.
pub(crate) const LAST_EXECUTE_INPUT_FILE: &str = "last_execute_input.hex";
/// `BlockExecution` log search windows up to the fork block: public RPCs cap a search at
/// 50,000 blocks.
const EXECUTE_LOG_WINDOWS: [u64; 2] = [5_000, 50_000];
/// EIP-1967's implementation slot.
const EIP1967_IMPLEMENTATION_SLOT: B256 =
    b256!("360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");

/// The fork the bundle was replayed on: reads through `provider`, impersonated sends through
/// `common::anvil`.
struct Fork {
    rpc_url: String,
    provider: AlloyProvider,
}

impl Fork {
    /// Sends `data` from `from` with the gas the node estimates plus a quarter.
    async fn send(
        &self,
        from: Address,
        to: Address,
        data: Vec<u8>,
        what: &str,
    ) -> anyhow::Result<()> {
        let request = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data.clone());
        let gas = self
            .provider
            .estimate_gas(request)
            .await
            .with_context(|| format!("{what}: eth_estimateGas ({from} -> {to})"))?;
        send_impersonated_tx(&self.rpc_url, from, to, data.into(), gas + gas / 4)
            .await
            .with_context(|| what.to_string())?;
        logger::info(format!("sent {what}"));
        Ok(())
    }

    /// Sends each call from `from`; the replay can't send value.
    async fn send_calls(
        &self,
        from: Address,
        calls: &[GovernanceCall],
        what: &str,
    ) -> anyhow::Result<()> {
        for (index, call) in calls.iter().enumerate() {
            anyhow::ensure!(call.value.is_zero(), "{what} call #{index} sends value");
            let selector = Bytes::copy_from_slice(&call.data[..call.data.len().min(4)]);
            let label = format!("{what} call #{index} ({selector} -> {})", call.target);
            self.send(from, call.target, call.data.clone(), &label)
                .await?;
        }
        Ok(())
    }

    /// An `eth_call` that must revert with `E`.
    async fn expect_revert<E: SolError>(
        &self,
        from: Address,
        to: Address,
        data: &[u8],
        what: &str,
    ) -> anyhow::Result<()> {
        let request = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data.to_vec());
        let error = match self.provider.call(request).await {
            Ok(_) => anyhow::bail!("{what} doesn't revert, expected {}", E::SIGNATURE),
            Err(error) => error,
        };
        match execution_revert_data(&error) {
            Some(revert) if revert.starts_with(&E::SELECTOR) => {
                logger::info(format!("{what} reverts with {}", E::SIGNATURE));
                Ok(())
            }
            Some(revert) => {
                anyhow::bail!("{what} reverts with {revert}, expected {}", E::SIGNATURE)
            }
            None => Err(error).with_context(|| format!("eth_call {from} -> {to}")),
        }
    }

    async fn slot_address(&self, proxy: Address, slot: B256) -> anyhow::Result<Address> {
        let word = self
            .provider
            .get_storage_at(proxy, slot.into())
            .await
            .with_context(|| format!("eth_getStorageAt({proxy}, {slot})"))?;
        Ok(Address::from_word(word.into()))
    }

    async fn latest_timestamp(&self) -> anyhow::Result<u64> {
        let block = self
            .provider
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await?
            .ok_or_else(|| anyhow::anyhow!("no latest block"))?;
        Ok(block.header.timestamp)
    }
}

/// `ChainAdmin.multicall(calls, true)`.
fn multicall(calls: &[GovernanceCall]) -> Vec<u8> {
    let calls = calls
        .iter()
        .map(|call| IChainAdminOwnable::Call {
            target: call.target,
            value: call.value,
            data: call.data.clone().into(),
        })
        .collect();
    ChainAdminOwnableAbi::multicallCall {
        _calls: calls,
        _requireSuccess: true,
    }
    .abi_encode()
}

/// `initialForceDeploymentHash` as the CTM computes it: keccak of `abi.encode(bytes)`, the
/// offset and length words followed by the padded data, not of the raw bytes.
fn force_deployments_hash(data: &Bytes) -> B256 {
    keccak256(data.abi_encode())
}

/// What the replay reads before sending anything.
struct Facts {
    ctm: Address,
    ctm_owner: Address,
    server_notifier: Address,
    bridgehub: Address,
    /// The reference chain: the one `test_upgrade_chain` upgrades.
    diamond: Address,
    chain_id: u64,
    chain_admin: Address,
    chain_admin_owner: Address,
}

/// The chains the fork tests are pointed at.
pub(crate) struct ReplayedChains {
    pub reference: u64,
    /// The reference chain if it upgraded, else the test chain.
    pub upgraded: u64,
    pub test: u64,
}

/// Replays the upgrade on the fork as whoever executes it would, checking the CTM and the
/// reference chain on the way. Stops at the first failure: later steps need the state.
pub(crate) async fn replay(
    rpc_url: &str,
    env_cfg: &EnvConfig,
    output: &UpgradeOutput,
    fork_block: u64,
    work_dir: &Path,
) -> anyhow::Result<ReplayedChains> {
    let fork = Fork {
        rpc_url: rpc_url.to_string(),
        provider: get_read_provider(rpc_url)?,
    };
    let facts = read_facts(&fork, env_cfg, output)
        .await
        .context("the facts")?;
    upgrade_server_notifier(&fork, output, &facts)
        .await
        .context("the ServerNotifier upgrade")?;
    replay_stages(&fork, output, &facts)
        .await
        .context("the governance stages")?;
    let upgraded = upgrade_reference_chain(&fork, output, &facts)
        .await
        .with_context(|| format!("chain {}", facts.chain_id))?;
    let test = create_test_chain(&fork, output, &facts)
        .await
        .context("the test chain")?;
    if upgraded {
        write_last_execute_input(&fork, &facts, fork_block, work_dir)
            .await
            .context("the last execute transaction")?;
    }
    Ok(ReplayedChains {
        reference: facts.chain_id,
        upgraded: if upgraded { facts.chain_id } else { test },
        test,
    })
}

async fn read_facts(
    fork: &Fork,
    env_cfg: &EnvConfig,
    output: &UpgradeOutput,
) -> anyhow::Result<Facts> {
    let provider = &fork.provider;
    let mut report = Report::default();
    let l1_chain_id = env_cfg
        .l1_chain_id()
        .ok_or_else(|| anyhow::anyhow!("permanent values have no l1_chain_id"))?;
    report.equal(
        "the RPC's chain id = l1_chain_id",
        provider.get_chain_id().await?,
        l1_chain_id,
    );

    let ctm = output.state_transition_address("chain_type_manager_proxy")?;
    let calls = &output.test_upgrade_calls.test_upgrade_chain;
    let diamond = calls
        .first()
        .map(|call| call.target)
        .filter(|diamond| calls.iter().all(|call| call.target == *diamond))
        .ok_or_else(|| anyhow::anyhow!("test_upgrade_chain must call one chain"))?;
    let chain_id = u64::try_from(
        ZkChainAbi::new(diamond, provider.clone())
            .getChainId()
            .call()
            .await?,
    )?;
    let bridgehub = env_cfg.bridgehub();
    report.equal(
        &format!("the bridgehub's chainTypeManager({chain_id}) = state_transition.chain_type_manager_proxy"),
        BridgehubAbi::new(bridgehub, provider.clone())
            .chainTypeManager(U256::from(chain_id))
            .call()
            .await?,
        ctm,
    );
    report.equal(
        "the CTM's BRIDGE_HUB() = bridgehub_proxy_addr",
        IChainTypeManagerAbi::new(ctm, provider.clone())
            .BRIDGE_HUB()
            .call()
            .await?,
        bridgehub,
    );
    report.finish()?;

    // `Utils.adminExecuteCalls` sends to an Ownable ChainAdmin from its owner; a
    // restriction-based one has no owner() and would need its restriction's admin instead.
    let chain_admin = output.test_upgrade_calls.test_upgrade_chain_caller;
    let chain_admin_owner = match IOwnable::new(chain_admin, provider.clone())
        .owner()
        .call()
        .await
    {
        Ok(owner) => owner,
        Err(error) if reverted_without_data(&error) => {
            anyhow::bail!(
                "ChainAdmin {chain_admin} has no owner(): restriction-based ChainAdmins aren't \
                 supported, only Ownable ones"
            )
        }
        Err(error) => return Err(error).context("ChainAdmin owner()"),
    };
    let facts = Facts {
        ctm,
        ctm_owner: IOwnable::new(ctm, provider.clone()).owner().call().await?,
        server_notifier: IChainTypeManagerAbi::new(ctm, provider.clone())
            .serverNotifierAddress()
            .call()
            .await?,
        bridgehub,
        diamond,
        chain_id,
        chain_admin,
        chain_admin_owner,
    };
    for sender in [
        facts.ctm_owner,
        facts.chain_admin_owner,
        output.ctm_admin_calls.chain_admin_owner,
        output.test_upgrade_calls.test_create_chain_caller,
    ] {
        set_balance(&fork.rpc_url, sender).await?;
    }
    Ok(facts)
}

async fn upgrade_server_notifier(
    fork: &Fork,
    output: &UpgradeOutput,
    facts: &Facts,
) -> anyhow::Result<()> {
    let admin = &output.ctm_admin_calls;
    fork.send(
        admin.chain_admin_owner,
        admin.chain_admin,
        multicall(&admin.server_notifier_upgrade),
        "ctm_admin_calls.server_notifier_upgrade",
    )
    .await?;
    let mut report = Report::default();
    report.equal(
        "ServerNotifier implementation = state_transition.server_notifier_implementation_addr",
        fork.slot_address(facts.server_notifier, EIP1967_IMPLEMENTATION_SLOT)
            .await?,
        output.state_transition_address("server_notifier_implementation_addr")?,
    );
    report.finish()
}

/// The CTM state its proxy upgrade must keep: owner, admin, ServerNotifier, ValidatorTimelock,
/// initial cut hash, and the reference chain's diamond.
async fn ctm_kept_state(
    fork: &Fork,
    facts: &Facts,
) -> anyhow::Result<(Address, Address, Address, Address, B256, Address)> {
    let ctm = IChainTypeManagerAbi::new(facts.ctm, fork.provider.clone());
    Ok((
        IOwnable::new(facts.ctm, fork.provider.clone())
            .owner()
            .call()
            .await?,
        IChainTypeManagerExt::new(facts.ctm, fork.provider.clone())
            .admin()
            .call()
            .await?,
        ctm.serverNotifierAddress().call().await?,
        ctm.validatorTimelockPostV29().call().await?,
        ctm.initialCutHash().call().await?,
        ctm.getZKChain(U256::from(facts.chain_id)).call().await?,
    ))
}

/// Stages 0–2 from the CTM's owner: with a timer, its deadline after stage 0 and a warp past
/// it; stage 1 split around the CTM's proxy upgrade to check what it keeps; then the CTM.
async fn replay_stages(fork: &Fork, output: &UpgradeOutput, facts: &Facts) -> anyhow::Result<()> {
    let provider = &fork.provider;
    let config = &output.contracts_config;
    let stages = &output.governance_calls;
    let (old, new) = (
        U256::from(config.old_protocol_version),
        U256::from(config.new_protocol_version),
    );
    let ctm = IChainTypeManagerAbi::new(facts.ctm, provider.clone());
    let ext = IChainTypeManagerExt::new(facts.ctm, provider.clone());
    let old_pointer = ext.newChainCreationParamsBlock(old).call().await?;
    let old_is_testnet = resolve_is_testnet_verifier(&fork.rpc_url, facts.ctm)
        .await
        .context("the old version's verifier")?;

    let started_after = fork.latest_timestamp().await?;
    fork.send_calls(facts.ctm_owner, &stages.stage0_calls, "stage 0")
        .await?;
    let timer = output
        .deployed_addresses
        .get("l1_governance_upgrade_timer")
        .filter(|timer| !timer.is_zero());
    if let Some(timer) = timer {
        let now = fork.latest_timestamp().await?;
        let deadline = u64::try_from(
            IGovernanceUpgradeTimer::new(*timer, provider.clone())
                .deadline()
                .call()
                .await?,
        )?;
        let delay = config.governance_upgrade_timer_initial_delay;
        anyhow::ensure!(
            deadline >= started_after + delay && deadline <= now + delay,
            "timer deadline {deadline} is not a stage-0 block's time + \
             governance_upgrade_timer_initial_delay ({delay})"
        );
        if deadline > now {
            let check = IGovernanceUpgradeTimer::checkDeadlineCall {}.abi_encode();
            fork.expect_revert::<DeadlineNotYetPassed>(
                facts.ctm_owner,
                *timer,
                &check,
                "checkDeadline() before the delay",
            )
            .await?;
            evm_increase_time_and_mine(&fork.rpc_url, deadline - now).await?;
            logger::info(format!("advanced the fork's time by {} s", deadline - now));
        }
    }

    let proxy_admin = fork
        .slot_address(facts.ctm, EIP1967_PROXY_ADMIN_SLOT.parse()?)
        .await?;
    let is_ctm_upgrade = |call: &GovernanceCall| {
        call.target == proxy_admin
            && IProxyAdmin::upgradeCall::abi_decode(&call.data)
                .is_ok_and(|upgrade| upgrade.proxy == facts.ctm)
    };
    let stage1 = &stages.stage1_calls;
    let upgrades: Vec<usize> = (0..stage1.len())
        .filter(|&i| is_ctm_upgrade(&stage1[i]))
        .collect();
    let [split] = upgrades[..] else {
        anyhow::bail!(
            "stage 1 has {} ProxyAdmin({proxy_admin}).upgrade calls for the CTM, expected one",
            upgrades.len()
        );
    };
    let kept = ctm_kept_state(fork, facts).await?;
    let before_stage1 = provider.get_block_number().await?;
    fork.send_calls(facts.ctm_owner, &stage1[..=split], "stage 1")
        .await?;
    let mut report = Report::default();
    report.equal(
        "CTM implementation = state_transition.chain_type_manager_implementation_addr",
        fork.slot_address(facts.ctm, EIP1967_IMPLEMENTATION_SLOT)
            .await?,
        output.state_transition_address("chain_type_manager_implementation_addr")?,
    );
    let kept_after = ctm_kept_state(fork, facts).await?;
    if kept_after == kept {
        report.ok(
            "CTM owner, admin, ServerNotifier, ValidatorTimelock, initialCutHash and the \
             reference chain unchanged by its proxy upgrade",
        );
    } else {
        report.error(format!(
            "CTM state changed by its proxy upgrade: {kept:?} -> {kept_after:?}"
        ));
    }
    report.finish()?;
    fork.send_calls(facts.ctm_owner, &stage1[split + 1..], "stage 1")
        .await?;
    let stage1_end = provider.get_block_number().await?;
    fork.send_calls(facts.ctm_owner, &stages.stage2_calls, "stage 2")
        .await?;

    let mut report = Report::default();
    report.equal(
        "CTM protocolVersion() = new_protocol_version",
        ctm.protocolVersion().call().await?,
        new,
    );
    report.equal(
        "CTM protocolVersionVerifier(new) = state_transition.verifier_addr",
        ctm.protocolVersionVerifier(new).call().await?,
        output.state_transition_address("verifier_addr")?,
    );
    report.equal(
        "CTM upgradeCutHash(old) = keccak(chain_upgrade_diamond_cut)",
        ctm.upgradeCutHash(old).call().await?,
        keccak256(&output.chain_upgrade_diamond_cut),
    );
    report.equal(
        "CTM initialCutHash() = keccak(diamond_cut_data)",
        ctm.initialCutHash().call().await?,
        keccak256(&config.diamond_cut_data),
    );
    report.equal(
        "CTM initialForceDeploymentHash() = keccak(abi.encode(force_deployments_data))",
        ext.initialForceDeploymentHash().call().await?,
        force_deployments_hash(&config.force_deployments_data),
    );
    let chain_asset_handler = BridgehubAbi::new(facts.bridgehub, provider.clone())
        .chainAssetHandler()
        .call()
        .await?;
    report.equal(
        "migrations unpaused",
        IChainAssetHandlerAbi::new(chain_asset_handler, provider.clone())
            .migrationPaused()
            .call()
            .await?,
        false,
    );
    // setChainCreationParams keys the pointer under the CTM's current version, so it must run
    // after setNewVersionUpgrade; otherwise new chains can't find their creation params.
    let new_pointer = u64::try_from(ext.newChainCreationParamsBlock(new).call().await?)?;
    if (before_stage1 + 1..=stage1_end).contains(&new_pointer) {
        report.ok("CTM newChainCreationParamsBlock(new) is a stage-1 block");
    } else {
        report.error(format!(
            "CTM newChainCreationParamsBlock(new) = {new_pointer}, not a stage-1 block \
             ({}..={stage1_end})",
            before_stage1 + 1
        ));
    }
    report.equal(
        "CTM newChainCreationParamsBlock(old) unchanged",
        ext.newChainCreationParamsBlock(old).call().await?,
        old_pointer,
    );
    report.equal(
        "the new version's verifier's testnet flag = the old one's",
        resolve_is_testnet_verifier(&fork.rpc_url, facts.ctm).await?,
        old_is_testnet,
    );
    report.finish()
}

async fn batch_counts(
    chain: &ZkChainAbi::ZkChainAbiInstance<AlloyProvider>,
) -> anyhow::Result<[U256; 3]> {
    Ok([
        chain.getTotalBatchesCommitted().call().await?,
        chain.getTotalBatchesVerified().call().await?,
        chain.getTotalBatchesExecuted().call().await?,
    ])
}

/// The timestamp, sent as `Utils.adminExecuteCalls` sends it to an Ownable ChainAdmin (its
/// setter directly, the ServerNotifier's through `multicall`); the drain; the upgrade.
/// Returns whether the chain upgraded: it can't while an L2 upgrade is pending, which passes
/// only with `ALLOW_PENDING_L2_UPGRADE=1`.
async fn upgrade_reference_chain(
    fork: &Fork,
    output: &UpgradeOutput,
    facts: &Facts,
) -> anyhow::Result<bool> {
    let provider = &fork.provider;
    let (owner, chain_admin) = (facts.chain_admin_owner, facts.chain_admin);
    let config = &output.contracts_config;
    let (old, new) = (
        U256::from(config.old_protocol_version),
        U256::from(config.new_protocol_version),
    );
    let chain_id = U256::from(facts.chain_id);
    let timestamp = U256::from(fork.latest_timestamp().await?);

    let set_timestamp = ChainAdminOwnableAbi::setUpgradeTimestampCall {
        _protocolVersion: new,
        _upgradeTimestamp: timestamp,
    }
    .abi_encode();
    fork.send(
        owner,
        chain_admin,
        set_timestamp,
        "ChainAdmin.setUpgradeTimestamp",
    )
    .await?;
    let notify = GovernanceCall {
        target: facts.server_notifier,
        value: U256::ZERO,
        data: IServerNotifier::setUpgradeTimestampCall {
            _chainId: chain_id,
            _upgradeTimestamp: timestamp,
        }
        .abi_encode(),
    };
    fork.send(
        owner,
        chain_admin,
        multicall(&[notify]),
        "ChainAdmin multicall(ServerNotifier.setUpgradeTimestamp)",
    )
    .await?;
    let mut report = Report::default();
    report.equal(
        "ServerNotifier protocolVersionToUpgradeTimestamp(chain, old)",
        IServerNotifier::new(facts.server_notifier, provider.clone())
            .protocolVersionToUpgradeTimestamp(chain_id, old)
            .call()
            .await?,
        timestamp,
    );
    report.equal(
        "ChainAdmin protocolVersionToUpgradeTimestamp(new)",
        IChainAdminAbi::new(chain_admin, provider.clone())
            .protocolVersionToUpgradeTimestamp(new)
            .call()
            .await?,
        timestamp,
    );
    report.finish()?;

    let diamond = ZkChainAbi::new(facts.diamond, provider.clone());
    let upgrade = multicall(&output.test_upgrade_calls.test_upgrade_chain);
    let [committed, verified, executed] = batch_counts(&diamond).await?;
    logger::info(format!(
        "batches committed / verified / executed: {committed} / {verified} / {executed}"
    ));
    if committed != executed {
        fork.expect_revert::<NotAllBatchesExecuted>(
            owner,
            chain_admin,
            &upgrade,
            "the upgrade with batches in flight (its upgrade contract must refuse them, as v31's \
             and v34's do)",
        )
        .await?;
        drain(fork, facts, executed).await?;
    } else {
        logger::info("no batches in flight: the NotAllBatchesExecuted check is skipped");
    }

    let pending = diamond.getL2SystemContractsUpgradeTxHash().call().await?;
    if !pending.is_zero() {
        fork.expect_revert::<PreviousUpgradeNotFinalized>(
            owner,
            chain_admin,
            &upgrade,
            "the upgrade with an L2 upgrade pending",
        )
        .await?;
        anyhow::ensure!(
            std::env::var("ALLOW_PENDING_L2_UPGRADE").as_deref() == Ok("1"),
            "an L2 upgrade ({pending}) is pending, so the chain's upgrade can't be rehearsed; \
             ALLOW_PENDING_L2_UPGRADE=1 accepts the test chain's instead"
        );
        logger::warn("ALLOW_PENDING_L2_UPGRADE=1: the fork tests run on the test chain");
        return Ok(false);
    }
    fork.send(
        owner,
        chain_admin,
        upgrade,
        "ChainAdmin multicall(test_upgrade_chain)",
    )
    .await?;
    let mut report = Report::default();
    report.equal(
        "chain protocol version = new_protocol_version",
        diamond.getProtocolVersion().call().await?,
        new,
    );
    report.finish()?;
    Ok(true)
}

/// Reverts the unexecuted batches through the ValidatorTimelock, as a `REVERTER_ROLE` holder
/// other than the timelock itself.
async fn drain(fork: &Fork, facts: &Facts, executed: U256) -> anyhow::Result<()> {
    let provider = &fork.provider;
    let timelock = IChainTypeManagerAbi::new(facts.ctm, provider.clone())
        .validatorTimelockPostV29()
        .call()
        .await?;
    let role = ValidatorTimelockAbi::new(timelock, provider.clone())
        .REVERTER_ROLE()
        .call()
        .await?;
    let roles = IPerChainRoles::new(timelock, provider.clone());
    let count = u64::try_from(roles.getRoleMemberCount(facts.diamond, role).call().await?)?;
    let mut reverter = None;
    for index in 0..count {
        let member = roles
            .getRoleMember(facts.diamond, role, U256::from(index))
            .call()
            .await?;
        if member != timelock {
            reverter = Some(member);
            break;
        }
    }
    let reverter =
        reverter.ok_or_else(|| anyhow::anyhow!("no REVERTER_ROLE holder on {timelock}"))?;
    set_balance(&fork.rpc_url, reverter).await?;
    let revert = ValidatorTimelockAbi::revertBatchesSharedBridgeCall {
        _chainAddress: facts.diamond,
        _newLastBatch: executed,
    }
    .abi_encode();
    fork.send(
        reverter,
        timelock,
        revert,
        &format!("revertBatchesSharedBridge to batch {executed}"),
    )
    .await?;
    let counts = batch_counts(&ZkChainAbi::new(facts.diamond, provider.clone())).await?;
    anyhow::ensure!(
        counts == [executed; 3],
        "not drained: committed / verified / executed = {} / {} / {}",
        counts[0],
        counts[1],
        counts[2]
    );
    Ok(())
}

/// Sends `test_create_chain` from its caller; the chain must be registered.
async fn create_test_chain(
    fork: &Fork,
    output: &UpgradeOutput,
    facts: &Facts,
) -> anyhow::Result<u64> {
    let calls = &output.test_upgrade_calls.test_create_chain;
    let chain_ids = calls
        .iter()
        .filter(|call| {
            call.data
                .starts_with(&BridgehubAbi::createNewChainCall::SELECTOR)
        })
        .map(|call| {
            Ok(u64::try_from(
                BridgehubAbi::createNewChainCall::abi_decode(&call.data)?._chainId,
            )?)
        })
        .collect::<anyhow::Result<Vec<u64>>>()?;
    let [chain_id] = chain_ids[..] else {
        anyhow::bail!(
            "test_create_chain has {} createNewChain calls, expected one",
            chain_ids.len()
        );
    };
    fork.send_calls(
        output.test_upgrade_calls.test_create_chain_caller,
        calls,
        "test_create_chain",
    )
    .await?;
    let chain = BridgehubAbi::new(facts.bridgehub, fork.provider.clone())
        .getZKChain(U256::from(chain_id))
        .call()
        .await?;
    anyhow::ensure!(!chain.is_zero(), "test chain {chain_id} is not registered");
    Report::default().ok(format!("test chain {chain_id} created at {chain}"));
    Ok(chain_id)
}

/// The raw input of the transaction that executed the reference chain's last batch, as `0x`
/// hex without a newline. Decoding it is version-specific, so it stays in the fork tests.
async fn write_last_execute_input(
    fork: &Fork,
    facts: &Facts,
    fork_block: u64,
    work_dir: &Path,
) -> anyhow::Result<()> {
    let provider = &fork.provider;
    let batch = ZkChainAbi::new(facts.diamond, provider.clone())
        .getTotalBatchesExecuted()
        .call()
        .await?;
    let mut logs = Vec::new();
    for window in EXECUTE_LOG_WINDOWS {
        let filter = Filter::new()
            .address(facts.diamond)
            .event_signature(keccak256("BlockExecution(uint256,bytes32,bytes32)"))
            .topic1(B256::from(batch))
            .from_block(fork_block.saturating_sub(window - 1))
            .to_block(fork_block);
        logs = provider.get_logs(&filter).await.context("eth_getLogs")?;
        if !logs.is_empty() {
            break;
        }
    }
    let [log] = &logs[..] else {
        anyhow::bail!(
            "{} BlockExecution logs for batch {batch} in the {} blocks up to {fork_block}",
            logs.len(),
            EXECUTE_LOG_WINDOWS[EXECUTE_LOG_WINDOWS.len() - 1]
        );
    };
    let hash = log
        .transaction_hash
        .ok_or_else(|| anyhow::anyhow!("the BlockExecution log has no transaction hash"))?;
    let tx = provider
        .get_transaction_by_hash(hash)
        .await?
        .ok_or_else(|| anyhow::anyhow!("transaction {hash} not found"))?;
    let path = work_dir.join(LAST_EXECUTE_INPUT_FILE);
    fs::write(&path, tx.input().to_string())
        .with_context(|| format!("write {}", path.display()))?;
    Report::default().ok(format!(
        "batch {batch}'s execute transaction {hash} written to {}",
        path.display()
    ));
    Ok(())
}

// ─── fork_tests ──────────────────────────────────────────────────────────────────

/// `forge test --json` per suite, as far as the verdict reads it.
#[derive(Deserialize)]
struct SuiteResult {
    test_results: BTreeMap<String, TestResult>,
}

#[derive(Deserialize)]
struct TestResult {
    status: String,
    reason: Option<String>,
}

/// The verdict on one file's `forge test --json` run. It passes with a passed test and no
/// failed or skipped one; in an env its `may_skip_in` names, skips are allowed and an
/// all-skipped file passes. Output it doesn't know fails, so another forge's format can't pass.
/// `Ok` holds the allowed skips with forge's reasons.
fn fork_test_verdict(
    stdout: &str,
    exited_ok: bool,
    env: &str,
    test: &ForkTest,
) -> anyhow::Result<Vec<String>> {
    if stdout.trim().is_empty() {
        // Forge 1.5.1 prints nothing and exits 0 when no file matches.
        anyhow::ensure!(
            !exited_ok,
            "no results: no test file matches (missing or renamed?)"
        );
        anyhow::bail!("forge test failed without results");
    }
    let suites: BTreeMap<String, SuiteResult> = serde_json::from_str(stdout.trim())
        .context("forge test's JSON is not in Foundry v1.5.1's format")?;
    let may_skip = test.may_skip_in.iter().any(|listed| listed == env);
    let (mut passed, mut skips) = (0, Vec::new());
    for (suite, result) in &suites {
        for (name, test_result) in &result.test_results {
            let reason = test_result.reason.as_deref().unwrap_or("no reason");
            match test_result.status.as_str() {
                "Success" => passed += 1,
                "Failure" => anyhow::bail!("{suite} {name} failed: {reason}"),
                "Skipped" if may_skip => skips.push(format!("{suite} {name}: {reason}")),
                "Skipped" => anyhow::bail!("{suite} {name} skipped ({reason}) outside may_skip_in"),
                other => anyhow::bail!("{suite} {name}: unknown status {other:?}"),
            }
        }
    }
    anyhow::ensure!(passed + skips.len() > 0, "no results");
    anyhow::ensure!(passed > 0 || may_skip, "no test passed");
    anyhow::ensure!(exited_ok, "forge test exited with an error");
    Ok(skips)
}

/// Runs each fork test file on the replayed fork with the replay's exports; `CHECKS_DIR` holds
/// `deployments.json`, `last_execute_input.hex` and a copy of `ecosystem.toml`.
pub(crate) fn run_fork_tests(
    tests: &[ForkTest],
    env: &str,
    rpc_url: &str,
    fork_block: u64,
    chains: &ReplayedChains,
    ecosystem_toml: &Path,
    checks_dir: &Path,
) -> anyhow::Result<()> {
    fs::copy(ecosystem_toml, checks_dir.join("ecosystem.toml"))
        .context("copy ecosystem.toml into CHECKS_DIR")?;
    let exports = [
        ("L1_RPC_URL", rpc_url.to_string()),
        ("UPGRADE_ENV", env.to_string()),
        ("FORK_BLOCK", fork_block.to_string()),
        ("REFERENCE_CHAIN_ID", chains.reference.to_string()),
        ("UPGRADED_CHAIN_ID", chains.upgraded.to_string()),
        ("TEST_CHAIN_ID", chains.test.to_string()),
        ("CHECKS_DIR", checks_dir.display().to_string()),
    ];
    for (name, value) in &exports {
        logger::info(format!("{name}={value}"));
    }
    let l1_contracts = paths::resolve_l1_contracts_path()?;
    let version = Command::new("forge")
        .arg("--version")
        .output()
        .context("run forge --version")?;
    anyhow::ensure!(version.status.success(), "forge --version failed");
    logger::info(
        String::from_utf8_lossy(&version.stdout)
            .lines()
            .next()
            .unwrap_or_default(),
    );

    let mut report = Report::default();
    for test in tests {
        let out = Command::new("forge")
            .args([
                "test",
                "--fork-url",
                rpc_url,
                "--match-path",
                &test.path,
                "--json",
                "--no-storage-caching",
            ])
            .arg("--out")
            .arg(checks_dir.join("forge-out"))
            .arg("--cache-path")
            .arg(checks_dir.join("forge-cache"))
            .current_dir(&l1_contracts)
            .envs(exports.iter().map(|(name, value)| (name, value)))
            .output()
            .with_context(|| format!("run forge test for {}", test.path))?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        match fork_test_verdict(&stdout, out.status.success(), env, test) {
            Ok(skips) => {
                for skip in &skips {
                    logger::info(format!("allowed skip in {env}: {skip}"));
                }
                report.ok(format!("fork test {}", test.path));
            }
            Err(error) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let tail: Vec<&str> = stderr.lines().rev().take(20).collect();
                logger::warn(tail.into_iter().rev().collect::<Vec<_>>().join("\n"));
                report.error(format!("{}: {error:#}", test.path));
            }
        }
    }
    report.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::governance_calls::encode_calls;
    use crate::common::paths;
    use crate::upgrade_verification::versions::v31::utils::bytecode_verifier::{
        ContractHash, ContractHashes,
    };

    const SUPPLIER: Address = Address::repeat_byte(0x5b);
    const CTM: Address = Address::repeat_byte(0xc7);
    const CTM_IMPL: Address = Address::repeat_byte(0xc1);
    const TIMER: Address = Address::repeat_byte(0x71);

    fn calls_hex(calls: &[GovernanceCall]) -> String {
        format!("0x{}", alloy::hex::encode(encode_calls(calls)))
    }

    /// A base-layout output whose cut and stages come from v34 stage's committed output (its
    /// `contracts_config.upgrade_cut_data` is encoded like `chain_upgrade_diamond_cut`); the
    /// addresses are synthetic.
    fn base_layout_output() -> String {
        let l1_contracts = paths::resolve_l1_contracts_path().unwrap();
        let path = l1_contracts.join("upgrade-envs/v0.34.0-era/output/stage/ecosystem.toml");
        let committed: toml::Value = toml::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        let v34 = |table: &str, key: &str| committed[table][key].as_str().unwrap().to_string();
        let test_call = calls_hex(&[GovernanceCall {
            target: Address::repeat_byte(0xd1),
            value: U256::ZERO,
            data: vec![0xab],
        }]);
        format!(
            r#"chain_upgrade_diamond_cut = "{cut}"

[contracts_config]
diamond_cut_data = "0x01"
force_deployments_data = "0x02"
governance_upgrade_timer_initial_delay = 3600
is_testnet = true
new_protocol_version = 146028888064
old_protocol_version = 141733920768

[state_transition]
bytecodes_supplier_addr = "{SUPPLIER}"
chain_type_manager_proxy = "{CTM}"
chain_type_manager_implementation_addr = "{CTM_IMPL}"
state_transition_implementation_addr = "{CTM_IMPL}"
verifier_plonk_addr = "0x0000000000000000000000000000000000000000"

[deployed_addresses]
l1_governance_upgrade_timer = "{TIMER}"
validium_l1_da_validator_addr = "0x0000000000000000000000000000000000000000"

[governance_calls]
stage0_calls = "{stage0}"
stage1_calls = "{stage1}"
stage2_calls = "{stage2}"

[ctm_admin_calls]
chain_admin = "0x00000000000000000000000000000000000000a1"
chain_admin_owner = "0x00000000000000000000000000000000000000a2"
server_notifier_upgrade = "{test_call}"

[test_upgrade_calls]
test_upgrade_chain = "{test_call}"
test_upgrade_chain_caller = "0x00000000000000000000000000000000000000a3"
test_create_chain = "{test_call}"
test_create_chain_caller = "0x00000000000000000000000000000000000000a4"
"#,
            cut = v34("contracts_config", "upgrade_cut_data"),
            stage0 = v34("governance_calls", "stage0_calls"),
            stage1 = v34("governance_calls", "stage1_calls"),
            stage2 = v34("governance_calls", "stage2_calls"),
        )
    }

    #[test]
    fn reads_the_base_layout() {
        let raw = base_layout_output();
        let output = UpgradeOutput::parse(&raw).unwrap();
        assert_eq!(output.factory_deps.len(), 51);
        let stages = &output.governance_calls;
        let stage_sizes = [
            &stages.stage0_calls,
            &stages.stage1_calls,
            &stages.stage2_calls,
        ]
        .map(|calls| calls.len());
        assert_eq!(stage_sizes, [1, 3, 1]);
        let config = &output.contracts_config;
        assert_eq!(config.new_protocol_version, 146_028_888_064);
        assert_eq!(config.governance_upgrade_timer_initial_delay, 3600);
        assert_eq!(config.diamond_cut_data, Bytes::from(vec![0x01]));
        assert_eq!(
            output.test_upgrade_calls.test_upgrade_chain[0].data,
            vec![0xab]
        );
        assert_eq!(
            output
                .state_transition_address("bytecodes_supplier_addr")
                .unwrap(),
            SUPPLIER
        );
        assert!(output
            .state_transition_address("verifier_plonk_addr")
            .is_err());
        // Zero addresses are skipped; one address under two keys appears once.
        let addresses = output.output_addresses();
        let mut want = vec![CTM_IMPL, TIMER, SUPPLIER, CTM];
        want.sort();
        assert_eq!(addresses.keys().copied().collect::<Vec<_>>(), want);
        assert_eq!(
            addresses[&CTM_IMPL],
            "state_transition.chain_type_manager_implementation_addr / \
             state_transition.state_transition_implementation_addr"
        );
        // A missing key names itself.
        let error =
            UpgradeOutput::parse(&raw.replace("test_create_chain_caller", "x")).unwrap_err();
        assert!(
            format!("{error:#}").contains("test_create_chain_caller"),
            "{error:#}"
        );
    }

    const FACTORY: Address = Address::repeat_byte(0xfa);
    const SALT: B256 = B256::repeat_byte(0x5a);

    /// A synthetic bytecode (two words, the least `try_parse_bytecode` accepts) and a second one.
    fn bytecode(tag: u8) -> Vec<u8> {
        vec![tag; 64]
    }

    fn hashes() -> BytecodeVerifier {
        let entry = |name: &str, tag: u8| ContractHash {
            contract_name: name.to_string(),
            evm_bytecode_hash: Some(keccak256(bytecode(tag)).to_string()),
            evm_deployed_bytecode_hash: None,
            evm_deployed_bytecode_blake_hash: None,
            evm_deployed_bytecode_length: None,
            zk_bytecode_hash: None,
        };
        BytecodeVerifier::from_contract_hashes(ContractHashes {
            hashes: vec![
                entry("l1-contracts/Facet", 1),
                entry("da-contracts/Checker", 2),
            ],
        })
    }

    fn deploy(salt: B256, init_code: &[u8]) -> (DeployerTx, Address) {
        let tx = DeployerTx {
            to: FACTORY,
            value: "0".to_string(),
            data: [salt.as_slice(), init_code].concat().into(),
        };
        (
            tx,
            compute_create2_address_evm(FACTORY, salt, keccak256(init_code)),
        )
    }

    fn publication() -> DeployerTx {
        DeployerTx {
            to: SUPPLIER,
            value: "0x0".to_string(),
            data: IBytecodesSupplierPublish::publishEraBytecodesCall {
                _bytecodes: vec![Bytes::from(vec![1u8; 32])],
            }
            .abi_encode()
            .into(),
        }
    }

    /// The facet with one constructor word, and the checker without args.
    fn facet_init() -> Vec<u8> {
        [bytecode(1), vec![0x0a; 32]].concat()
    }

    /// Runs the rules with every deployed address in the output and undeployed at the fork
    /// block; returns the errors and what was identified.
    fn run(txs: &[DeployerTx], deployed: &[Address]) -> (Vec<String>, Deployments) {
        let output: BTreeMap<Address, String> = deployed
            .iter()
            .enumerate()
            .map(|(i, address)| (*address, format!("state_transition.key{i}")))
            .collect();
        let undeployed = deployed.iter().copied().collect();
        let mut report = Report::default();
        let found = identify_deployments(
            txs,
            FACTORY,
            SUPPLIER,
            &output,
            &undeployed,
            &hashes(),
            &mut report,
        );
        (report.errors, found)
    }

    #[test]
    fn identifies_deployments_and_publications() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (checker, checker_address) = deploy(SALT, &bytecode(2));
        let (errors, found) = run(
            &[facet, publication(), checker],
            &[facet_address, checker_address],
        );
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(found.salt, Some(SALT));
        let summary: Vec<_> = found
            .deployments
            .iter()
            .map(|d| (d.contract.as_str(), d.address, d.args.to_vec()))
            .collect();
        assert_eq!(
            summary,
            [
                ("l1-contracts/Facet", facet_address, vec![0x0a; 32]),
                ("da-contracts/Checker", checker_address, vec![]),
            ]
        );
    }

    #[test]
    fn rejects_tampered_init_code() {
        let mut init_code = facet_init();
        init_code[0] ^= 1;
        let (tx, address) = deploy(SALT, &init_code);
        let (errors, found) = run(&[tx], &[address]);
        assert!(
            errors[0].contains("no bytecode of AllContractsHashes.json"),
            "{errors:?}"
        );
        // The address it would have deployed stays undeployed.
        assert!(
            errors[1].contains("no deployer transaction deploys it"),
            "{errors:?}"
        );
        assert!(found.deployments.is_empty());
    }

    #[test]
    fn rejects_two_salts_and_value() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (mut checker, checker_address) = deploy(B256::repeat_byte(0x01), &bytecode(2));
        checker.value = "1".to_string();
        let (errors, _) = run(&[facet, checker], &[facet_address, checker_address]);
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(errors[0].contains("sends value 1"), "{errors:?}");
        assert!(errors[1].contains("uses salt"), "{errors:?}");
    }

    #[test]
    fn rejects_targets_the_output_does_not_list() {
        let (facet, _) = deploy(SALT, &facet_init());
        let stray = DeployerTx {
            to: Address::repeat_byte(0x99),
            value: "0".to_string(),
            data: Bytes::from(vec![1, 2, 3, 4]),
        };
        let (errors, _) = run(&[facet, stray], &[]);
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(
            errors[0].contains("which the output doesn't list"),
            "{errors:?}"
        );
        assert!(
            errors[1].contains("neither a CREATE2 deployment"),
            "{errors:?}"
        );
    }

    #[test]
    fn rejects_an_output_address_left_undeployed() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (_, checker_address) = deploy(SALT, &bytecode(2));
        let (errors, _) = run(&[facet], &[facet_address, checker_address]);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(
            errors[0].contains(&checker_address.to_string()),
            "{errors:?}"
        );
    }

    #[test]
    fn rejects_a_double_deployment() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (errors, found) = run(&[facet.clone(), facet], &[facet_address]);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(errors[0].contains("a second time"), "{errors:?}");
        assert_eq!(found.deployments.len(), 1);
    }

    #[test]
    fn the_force_deployment_hash_covers_abi_encoded_bytes() {
        let data = Bytes::from(vec![0x01, 0x02]);
        // abi.encode(bytes): the offset word, the length word, the data padded to a word.
        let mut encoded = vec![0u8; 96];
        encoded[31] = 0x20;
        encoded[63] = 2;
        encoded[64..66].copy_from_slice(&[0x01, 0x02]);
        assert_eq!(force_deployments_hash(&data), keccak256(&encoded));
        assert_ne!(force_deployments_hash(&data), keccak256(&data));
    }

    // `forge test --json` samples hand-written to Foundry v1.5.1's serde shape, not captured
    // (CI's generate jobs pin v1.5.1):
    // `{"<file>:<contract>": {"duration", "test_results": {"<test>": {"status", "reason", …}},
    // "warnings"}}`. A `vm.skip` in `setUp` comes back as one `setUp()` result.
    const PASSED: &str = r#"{"test/foundry/fork/V34EraUpgrade.t.sol:V34EraUpgradeTest":{"duration":"2.41s","test_results":{"test_chainState()":{"status":"Success","reason":null,"counterexample":null,"logs":[],"decoded_logs":[],"kind":{"Unit":{"gas":912345}},"traces":[],"labeled_addresses":{},"duration":{"secs":1,"nanos":20},"breakpoints":{},"gas_snapshots":{}},"test_proofSwitches()":{"status":"Success","reason":null,"counterexample":null,"logs":[],"decoded_logs":[],"kind":{"Unit":{"gas":512345}},"traces":[],"labeled_addresses":{},"duration":{"secs":0,"nanos":900},"breakpoints":{},"gas_snapshots":{}}},"warnings":[]}}"#;
    const SETUP_SKIPPED: &str = r#"{"test/foundry/fork/V34EraFirstBatch.t.sol:V34EraFirstBatchTest":{"duration":"0.12s","test_results":{"setUp()":{"status":"Skipped","reason":"run from rehearse.sh","counterexample":null,"logs":[],"decoded_logs":[],"kind":{"Unit":{"gas":0}},"traces":[],"labeled_addresses":{},"duration":{"secs":0,"nanos":0},"breakpoints":{},"gas_snapshots":{}}},"warnings":[]}}"#;

    const SUITE: &str = "test/foundry/fork/V34EraUpgrade.t.sol:V34EraUpgradeTest";

    fn fork_test(may_skip_in: &[&str]) -> ForkTest {
        ForkTest {
            path: "test/foundry/fork/V34EraUpgrade.t.sol".to_string(),
            may_skip_in: may_skip_in.iter().map(|env| env.to_string()).collect(),
        }
    }

    fn verdict(
        stdout: &str,
        exited_ok: bool,
        env: &str,
        may_skip_in: &[&str],
    ) -> Result<Vec<String>, String> {
        fork_test_verdict(stdout, exited_ok, env, &fork_test(may_skip_in))
            .map_err(|error| format!("{error:#}"))
    }

    #[test]
    fn a_fork_test_file_passes_only_with_a_passed_test_and_nothing_failed() {
        assert_eq!(verdict(PASSED, true, "testnet3", &[]), Ok(vec![]));
        let failed = PASSED.replacen(
            r#""status":"Success","reason":null"#,
            r#""status":"Failure","reason":"TooMuchGas()""#,
            1,
        );
        let error = verdict(&failed, false, "testnet3", &["testnet3"]).unwrap_err();
        assert!(
            error.contains("test_chainState() failed: TooMuchGas()"),
            "{error}"
        );
    }

    #[test]
    fn skips_pass_only_in_the_envs_a_file_names() {
        // One test skipped, one passed.
        let one_skipped = PASSED.replacen(
            r#""status":"Success","reason":null"#,
            r#""status":"Skipped","reason":"reference chain not upgraded""#,
            1,
        );
        assert_eq!(
            verdict(&one_skipped, true, "mainnet", &["mainnet"]),
            Ok(vec![format!(
                "{} test_chainState(): reference chain not upgraded",
                SUITE
            )])
        );
        let error = verdict(&one_skipped, true, "testnet3", &["mainnet"]).unwrap_err();
        assert!(
            error.contains("skipped (reference chain not upgraded) outside may_skip_in"),
            "{error}"
        );
        // A file all skipped, here in setUp: passes where it may skip, fails elsewhere, even
        // while another file passes.
        assert_eq!(
            verdict(SETUP_SKIPPED, true, "mainnet", &["mainnet"])
                .unwrap()
                .len(),
            1
        );
        assert!(verdict(SETUP_SKIPPED, true, "testnet3", &[])
            .unwrap_err()
            .contains("setUp() skipped"));
        assert!(verdict(PASSED, true, "testnet3", &[]).is_ok());
    }

    #[test]
    fn output_the_verdict_does_not_know_fails() {
        // Forge 1.5.1 prints nothing and exits 0 for a --match-path that matches no file.
        for may_skip_in in [&[][..], &["testnet3"][..]] {
            let error = verdict("", true, "testnet3", may_skip_in).unwrap_err();
            assert!(error.contains("no results"), "{error}");
            assert!(verdict("\n", false, "testnet3", may_skip_in).is_err());
        }
        let unknown = PASSED.replacen(r#""status":"Success""#, r#""status":"Ignored""#, 1);
        assert!(verdict(&unknown, true, "testnet3", &[])
            .unwrap_err()
            .contains("unknown status"));
        let renamed = PASSED.replace("test_results", "results");
        assert!(verdict(&renamed, true, "testnet3", &[])
            .unwrap_err()
            .contains("v1.5.1"));
        assert!(verdict("Compiling 3 files", true, "testnet3", &[]).is_err());
        assert!(verdict("{}", true, "testnet3", &["testnet3"])
            .unwrap_err()
            .contains("no results"));
        // Parsed, but forge said it failed.
        assert!(verdict(PASSED, false, "testnet3", &[])
            .unwrap_err()
            .contains("exited with an error"));
    }
}
