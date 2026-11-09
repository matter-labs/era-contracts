//! Built-in checks of a `forge-script` upgrade (`builtin_checks = true`), the same for every
//! upgrade of an Era CTM; what one upgrade must contain is left to its `fork_tests`, which the
//! files written here feed. They need an output in `DefaultCTMUpgrade.saveOutput`'s layout, a
//! minor-version upgrade whose upgrade contract refuses a chain with unexecuted batches (v31's
//! and v34's do), a CTM owned by a PUH, and an Ownable ChainAdmin on the reference chain.
//!
//! - publication (fork and chain): the L2 upgrade tx's factory deps are published, the output
//!   addresses have code, the output's CTM is the bridgehub's for the reference chain, and its
//!   supplier is the CTM's;
//! - provenance (fork): each deployer tx is a CREATE2 deployment through the env's factory of
//!   a bytecode in `AllContractsHashes.json`, or a publication; one salt; each deployment is an
//!   output address, and each output address without code at the fork block is deployed
//!   exactly once;
//! - replay (fork): the ServerNotifier upgrade and stages 0–2 from their real senders, the CTM
//!   checked after each, with anyone's `PUH.reinforceUnfreeze()` before stage 1, which must still
//!   pass; the reference chain's timestamp and upgrade as `chain
//!   set-upgrade-timestamp` and `chain upgrade` send them, around a drain; a test chain; the
//!   reference chain's last execute tx;
//! - `fork_tests`: the upgrade's Foundry files, on the replayed fork.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Display;
use std::fs;
use std::path::Path;
use std::process::Command;

use alloy::consensus::Transaction as _;
use alloy::eips::BlockNumberOrTag;
use alloy::network::TransactionBuilder;
use alloy::primitives::{address, keccak256, Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::rpc::types::{Filter, TransactionRequest};
use alloy::sol_types::{SolCall, SolError, SolValue};
use anyhow::Context;
use serde::Deserialize;

use crate::common::abi::chain_admin_ownable::IChainAdminOwnable;
use crate::common::abi::upgrade_errors::{DeadlineNotYetPassed, NotAllBatchesExecuted};
use crate::common::abi::{
    BridgehubAbi, ChainAdminOwnableAbi, IBytecodesSupplierPublish, IChainAdminAbi,
    IChainAssetHandlerAbi, IChainTypeManagerAbi, IChainTypeManagerExt, IGovernanceUpgradeTimer,
    IOwnable, IPerChainRoles, IProtocolUpgradeHandler, IProxyAdmin, IServerNotifier,
    ValidatorTimelockAbi, ZkChainAbi,
};
use crate::common::anvil::{evm_increase_time_and_mine, send_impersonated_tx, set_balance};
use crate::common::chain_upgrade_calls;
use crate::common::env_config::EnvConfig;
use crate::common::ethereum::{get_read_provider, AlloyProvider};
use crate::common::forge::{split_into_bundles, ForgeRunner, ForgeScriptArgs, SafeBundle};
use crate::common::governance_calls::{decode_calls, GovernanceCall};
use crate::common::l1_contracts::{
    execution_revert_data, resolve_bytecodes_supplier, resolve_is_testnet_verifier,
    resolve_is_zksync_os, reverted_without_data,
};
use crate::common::upgrade_descriptor::ForkTest;
use crate::common::{logger, output, paths, SharedRunArgs};
use crate::upgrade_verification::constants::{
    EIP1967_IMPLEMENTATION_SLOT, EIP1967_PROXY_ADMIN_SLOT,
};
use crate::upgrade_verification::verifiers::VerificationResult;
use crate::upgrade_verification::versions::v31::elements::set_new_version_upgrade::{
    upgradeCall, BytecodesSupplier, DiamondCutData,
};
use crate::upgrade_verification::versions::v31::utils::{
    bytecode_verifier::BytecodeVerifier, compute_create2_address_evm,
};

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
    /// The L2 upgrade tx's, decoded from the cut.
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

    pub(crate) fn state_transition_address(&self, key: &str) -> anyhow::Result<Address> {
        self.state_transition
            .get(key)
            .copied()
            .filter(|address| !address.is_zero())
            .ok_or_else(|| anyhow::anyhow!("state_transition.{key} is missing or zero"))
    }

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

/// A checker's findings, printed like PUVT's; `finish` fails listing every error.
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

/// Read-only, so safe against a real chain.
pub(crate) async fn check_publication(
    rpc_url: &str,
    output: &UpgradeOutput,
    bridgehub: Address,
) -> anyhow::Result<()> {
    let provider = get_read_provider(rpc_url)?;
    let mut report = Report::default();
    let supplier = output.state_transition_address("bytecodes_supplier_addr")?;
    let ctm = output.state_transition_address("chain_type_manager_proxy")?;
    // ZKsync OS publishes EVM bytecodes, into `evmPublishingBlock`.
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

    // A failed read is recorded, not fatal.
    let registered = async {
        let (_, chain_id) = reference_chain(&provider, output).await?;
        check_chain_ctm(&provider, bridgehub, chain_id, ctm, &mut report).await
    };
    if let Err(error) = registered.await {
        report.error(format!(
            "the bridgehub's CTM for the reference chain: {}",
            redact_urls(&format!("{error:#}"))
        ));
    }
    report.equal(
        "state_transition.bytecodes_supplier_addr = the CTM's L1_BYTECODES_SUPPLIER()",
        supplier,
        resolve_bytecodes_supplier(rpc_url, ctm).await?,
    );
    report.finish()
}

/// The reference chain's diamond: the one chain `test_upgrade_chain` calls.
fn reference_diamond(test_upgrade_chain: &[GovernanceCall]) -> anyhow::Result<Address> {
    test_upgrade_chain
        .first()
        .map(|call| call.target)
        .filter(|diamond| {
            test_upgrade_chain
                .iter()
                .all(|call| call.target == *diamond)
        })
        .ok_or_else(|| anyhow::anyhow!("test_upgrade_chain must call one chain"))
}

async fn reference_chain(
    provider: &AlloyProvider,
    output: &UpgradeOutput,
) -> anyhow::Result<(Address, u64)> {
    let diamond = reference_diamond(&output.test_upgrade_calls.test_upgrade_chain)?;
    let chain_id = ZkChainAbi::new(diamond, provider.clone())
        .getChainId()
        .call()
        .await
        .with_context(|| format!("getChainId() on {diamond}"))?;
    Ok((diamond, u64::try_from(chain_id)?))
}

/// By the bridgehub's registry, not the CTM's `BRIDGE_HUB()`: another CTM deployed with this
/// bridgehub returns it too.
async fn check_chain_ctm(
    provider: &AlloyProvider,
    bridgehub: Address,
    chain_id: u64,
    ctm: Address,
    report: &mut Report,
) -> anyhow::Result<()> {
    report.equal(
        &format!(
            "the bridgehub's chainTypeManager({chain_id}) = state_transition.chain_type_manager_proxy"
        ),
        BridgehubAbi::new(bridgehub, provider.clone())
            .chainTypeManager(U256::from(chain_id))
            .call()
            .await
            .with_context(|| format!("{bridgehub}.chainTypeManager({chain_id})"))?,
        ctm,
    );
    Ok(())
}

/// A transaction as a Safe bundle file holds it.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SafeTx {
    pub to: Address,
    /// Decimal or `0x` hex.
    pub value: String,
    pub data: Bytes,
}

pub(crate) async fn check_provenance(
    rpc_url: &str,
    output: &UpgradeOutput,
    factory: Address,
    txs: &[SafeTx],
    fork_block: u64,
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
    identify_deployments(
        txs,
        factory,
        supplier,
        &addresses,
        &undeployed,
        &hashes,
        &mut report,
    );
    report.finish()
}

/// The provenance rules, without RPC. `undeployed`: output addresses without code at the fork
/// block. Returns the deployed addresses in order.
fn identify_deployments(
    txs: &[SafeTx],
    factory: Address,
    supplier: Address,
    output: &BTreeMap<Address, String>,
    undeployed: &BTreeSet<Address>,
    hashes: &BytecodeVerifier,
    report: &mut Report,
) -> Vec<Address> {
    let publish = [
        IBytecodesSupplierPublish::publishEraBytecodeCall::SELECTOR,
        IBytecodesSupplierPublish::publishEraBytecodesCall::SELECTOR,
    ];
    let errors_before = report.errors.len();
    let mut salt: Option<B256> = None;
    let mut deployments: Vec<Address> = Vec::new();
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
        let Some((contract, _)) = hashes.try_parse_bytecode(init_code) else {
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
        } else if deployments.contains(&address) {
            report.error(format!("{label} deploys {address} a second time"));
        } else {
            deployments.push(address);
        }
    }
    for address in undeployed {
        if !deployments.contains(address) {
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
    deployments
}

// ─── The replay ──────────────────────────────────────────────────────────────────

/// For the first-batch fork test.
const LAST_EXECUTE_INPUT_FILE: &str = "last_execute_input.hex";
/// Blocks per `eth_getLogs`: thirdweb's Sepolia RPC caps it at 1,000.
const EXECUTE_LOG_WINDOW: u64 = 1_000;
/// Search depth: about a week of 12 s L1 blocks.
const EXECUTE_LOG_SPAN: u64 = 50_000;
/// Stands for anyone: `reinforceUnfreeze()` has no access control.
const ANYONE: Address = address!("1111111111111111111111111111111111111111");

/// The replay's Anvil: reads via `provider`, impersonated sends via `common::anvil`.
struct Fork {
    rpc_url: String,
    provider: AlloyProvider,
}

impl Fork {
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

    /// The replay can't send value.
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

    /// A `ForgeRunner` like the chain commands', on a fork of this Anvil.
    fn chain_command_runner(&self) -> anyhow::Result<ForgeRunner> {
        ForgeRunner::new(&SharedRunArgs {
            l1_rpc_url: self.rpc_url.clone(),
            out: None,
            subdir: None,
            forge_args: ForgeScriptArgs::default(),
        })
    }

    /// Sends what `runner` broadcast as `command` writes it into its Safe bundles. Stops the
    /// runner's Anvil first: it reads this one at the current block, which must stay the head
    /// while it runs.
    async fn send_broadcasts(&self, runner: ForgeRunner, command: &str) -> anyhow::Result<()> {
        let bundles = split_into_bundles(&runner, command)?;
        drop(runner);
        let calls = bundle_calls(&bundles)?;
        anyhow::ensure!(!calls.is_empty(), "{command} broadcast nothing");
        // The command funded its senders on its own fork only.
        for from in calls.iter().map(|(from, _)| *from).collect::<BTreeSet<_>>() {
            set_balance(&self.rpc_url, from).await?;
        }
        for (index, (from, tx)) in calls.into_iter().enumerate() {
            let label = format!("{command} tx #{index} ({from} -> {})", tx.to);
            self.send(from, tx.to, tx.data.into(), &label).await?;
        }
        Ok(())
    }

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

/// Each bundle's transactions with its signer. The replay can't send value.
fn bundle_calls(bundles: &[SafeBundle]) -> anyhow::Result<Vec<(Address, SafeTx)>> {
    let mut calls = Vec::new();
    for bundle in bundles {
        let from: Address = bundle
            .target
            .parse()
            .with_context(|| format!("bundle signer {:?}", bundle.target))?;
        for tx in output::safe_txs_from_bundle(bundle)? {
            let tx: SafeTx = serde_json::from_value(tx)?;
            anyhow::ensure!(
                tx.value.parse::<U256>().is_ok_and(|value| value.is_zero()),
                "a transaction from {from} to {} sends value {}",
                tx.to,
                tx.value
            );
            calls.push((from, tx));
        }
    }
    Ok(calls)
}

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

/// `initialForceDeploymentHash` as the CTM computes it: keccak of `abi.encode(bytes)`, not of
/// the raw bytes.
fn force_deployments_hash(data: &Bytes) -> B256 {
    keccak256(data.abi_encode())
}

/// What the replay reads before sending anything.
struct Facts {
    ctm: Address,
    ctm_owner: Address,
    server_notifier: Address,
    bridgehub: Address,
    /// The reference chain's.
    diamond: Address,
    chain_id: u64,
    chain_admin: Address,
    chain_admin_owner: Address,
}

/// The chains the fork tests are pointed at.
pub(crate) struct ReplayedChains {
    pub reference: u64,
    pub test: u64,
}

/// Stops at the first failure, as later steps need the state.
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
    upgrade_reference_chain(&fork, output, &facts)
        .await
        .with_context(|| format!("chain {}", facts.chain_id))?;
    let test = create_test_chain(&fork, output, &facts)
        .await
        .context("the test chain")?;
    write_last_execute_input(&fork, &facts, fork_block, work_dir)
        .await
        .context("the reference chain's last execute transaction")?;
    Ok(ReplayedChains {
        reference: facts.chain_id,
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
    let (diamond, chain_id) = reference_chain(provider, output).await?;
    let bridgehub = env_cfg.bridgehub();
    check_chain_ctm(provider, bridgehub, chain_id, ctm, &mut report).await?;
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
    // restriction-based one would need its restriction's admin.
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
        ANYONE,
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
        fork.slot_address(facts.server_notifier, EIP1967_IMPLEMENTATION_SLOT.parse()?)
            .await?,
        output.state_transition_address("server_notifier_implementation_addr")?,
    );
    report.finish()
}

/// The CTM state its proxy upgrade must keep.
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

/// Each stage's calls in turn from the CTM's owner, as on the normal path, past the timer's delay.
/// Stage 1 is split around the CTM's proxy upgrade to check what it keeps.
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
    let chain_asset_handler = IChainAssetHandlerAbi::new(
        BridgehubAbi::new(facts.bridgehub, provider.clone())
            .chainAssetHandler()
            .call()
            .await?,
        provider.clone(),
    );
    let old_pointer = ext.newChainCreationParamsBlock(old).call().await?;
    let old_is_testnet = resolve_is_testnet_verifier(&fork.rpc_url, facts.ctm)
        .await
        .context("the old version's verifier")?;

    let started_after = fork.latest_timestamp().await?;
    fork.send_calls(facts.ctm_owner, &stages.stage0_calls, "stage 0")
        .await?;
    // Stage 0 pauses migrations for the delay before stage 1.
    let mut report = Report::default();
    report.equal(
        "migrations paused after stage 0",
        chain_asset_handler.migrationPaused().call().await?,
        true,
    );
    report.finish()?;
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

    // Anyone can unpause migrations between the stages: the PUH's `reinforceUnfreeze()` needs only
    // an unfrozen protocol. A stage 1 that doesn't re-pause reverts at `checkMigrationsPaused()`.
    fork.send(
        ANYONE,
        facts.ctm_owner,
        IProtocolUpgradeHandler::reinforceUnfreezeCall {}.abi_encode(),
        &format!("PUH.reinforceUnfreeze() from {ANYONE}"),
    )
    .await?;
    let mut report = Report::default();
    // It swallows its calls' failures.
    report.equal(
        "migrations unpaused by reinforceUnfreeze()",
        chain_asset_handler.migrationPaused().call().await?,
        false,
    );
    report.finish()?;

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
        fork.slot_address(facts.ctm, EIP1967_IMPLEMENTATION_SLOT.parse()?)
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
    report.equal(
        "migrations unpaused",
        chain_asset_handler.migrationPaused().call().await?,
        false,
    );
    // setChainCreationParams keys the pointer by the CTM's current version: run before
    // setNewVersionUpgrade, it leaves new chains without creation params.
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

/// The timestamp, the drain and the upgrade, the chain commands' calls from their senders. A
/// pending L2 upgrade fails it up front: the upgrade would revert `PreviousUpgradeNotFinalized`,
/// and nothing here clears it.
async fn upgrade_reference_chain(
    fork: &Fork,
    output: &UpgradeOutput,
    facts: &Facts,
) -> anyhow::Result<()> {
    let provider = &fork.provider;
    let diamond = ZkChainAbi::new(facts.diamond, provider.clone());
    let pending = diamond.getL2SystemContractsUpgradeTxHash().call().await?;
    anyhow::ensure!(
        pending.is_zero(),
        "a pending L2 upgrade ({pending}) blocks the upgrade; wait until its first batch on its \
         current version executes"
    );
    let (owner, chain_admin) = (facts.chain_admin_owner, facts.chain_admin);
    let config = &output.contracts_config;
    let (old, new) = (
        U256::from(config.old_protocol_version),
        U256::from(config.new_protocol_version),
    );
    let chain_id = U256::from(facts.chain_id);
    let timestamp = U256::from(fork.latest_timestamp().await?);

    // An Ownable ChainAdmin: no AccessControlRestriction.
    let mut runner = fork.chain_command_runner()?;
    chain_upgrade_calls::set_upgrade_timestamp(
        &runner,
        facts.bridgehub,
        facts.chain_id,
        Address::ZERO,
        new,
        timestamp,
    )
    .await?
    .run(&mut runner)?;
    fork.send_broadcasts(runner, "chain set-upgrade-timestamp")
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

    let [committed, verified, executed] = batch_counts(&diamond).await?;
    logger::info(format!(
        "batches committed / verified / executed: {committed} / {verified} / {executed}"
    ));
    if committed != executed {
        // The output's upgrade calls: `chain upgrade`'s script reverts here before it broadcasts.
        fork.expect_revert::<NotAllBatchesExecuted>(
            owner,
            chain_admin,
            &multicall(&output.test_upgrade_calls.test_upgrade_chain),
            "ChainAdmin multicall(test_upgrade_chain) with batches in flight (its upgrade \
             contract must refuse them, as v31's and v34's do)",
        )
        .await?;
        drain(fork, facts, executed).await?;
    } else {
        logger::info("no batches in flight: the NotAllBatchesExecuted check is skipped");
    }
    let mut runner = fork.chain_command_runner()?;
    let (_, upgrade) = chain_upgrade_calls::upgrade(
        &runner,
        facts.bridgehub,
        facts.chain_id,
        Address::ZERO,
        None,
    )
    .await?;
    upgrade.run(&mut runner)?;
    fork.send_broadcasts(runner, "chain upgrade").await?;
    let mut report = Report::default();
    report.equal(
        "chain protocol version = new_protocol_version",
        diamond.getProtocolVersion().call().await?,
        new,
    );
    report.finish()
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

/// As raw `0x` hex without a newline: decoding is version-specific, so the fork tests do it.
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
    let filter = Filter::new()
        .address(facts.diamond)
        .event_signature(keccak256("BlockExecution(uint256,bytes32,bytes32)"))
        .topic1(B256::from(batch));
    let (mut logs, mut searched_from) = (Vec::new(), fork_block);
    for (from, to) in execute_log_windows(fork_block) {
        let window = filter.clone().from_block(from).to_block(to);
        logs = provider.get_logs(&window).await.context("eth_getLogs")?;
        searched_from = from;
        if !logs.is_empty() {
            break;
        }
    }
    let [log] = &logs[..] else {
        anyhow::bail!(
            "{} BlockExecution logs for batch {batch} in the {} blocks up to {fork_block}",
            logs.len(),
            fork_block - searched_from + 1
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

/// Inclusive `(from, to)` ranges, newest first: adjacent `EXECUTE_LOG_WINDOW`s covering
/// `EXECUTE_LOG_SPAN` blocks up to `fork_block`, or down to block 0.
fn execute_log_windows(fork_block: u64) -> Vec<(u64, u64)> {
    let lowest = fork_block.saturating_sub(EXECUTE_LOG_SPAN - 1);
    let mut windows = Vec::new();
    let mut to = fork_block;
    loop {
        let from = to.saturating_sub(EXECUTE_LOG_WINDOW - 1).max(lowest);
        windows.push((from, to));
        if from == lowest {
            return windows;
        }
        to = from - 1;
    }
}

// ─── fork_tests ──────────────────────────────────────────────────────────────────

/// `forge test --json`'s result for one suite, as far as the verdict reads it.
#[derive(Deserialize)]
struct SuiteResult {
    test_results: BTreeMap<String, TestResult>,
}

#[derive(Deserialize)]
struct TestResult {
    status: TestStatus,
    /// Forge's reason for a failure or skip, e.g. the failed assertion.
    reason: Option<String>,
}

/// Foundry v1.5.1's; any other status fails to parse.
#[derive(Debug, Deserialize)]
enum TestStatus {
    Success,
    Failure,
    Skipped,
}

/// A file passes when forge exits 0 and every one of its tests, at least one, passed. `stdout`
/// must be the JSON result alone, so anything else forge prints fails it. A failure carries
/// forge's reason with its URLs redacted: `Report::error` prints it before `CheckFailures` would.
fn fork_test_verdict(stdout: &str, exited_ok: bool) -> anyhow::Result<()> {
    let suites = serde_json::from_str::<BTreeMap<String, SuiteResult>>(stdout);
    if let Ok(suites) = &suites {
        let not_passed: Vec<String> = suites
            .iter()
            .flat_map(|(suite, result)| {
                result
                    .test_results
                    .iter()
                    .filter(|(_, test)| !matches!(test.status, TestStatus::Success))
                    .map(move |(name, test)| {
                        let reason = test
                            .reason
                            .as_deref()
                            .map_or(String::new(), |reason| format!(": {}", redact_urls(reason)));
                        format!("{suite} {name}: {:?}{reason}", test.status)
                    })
            })
            .collect();
        anyhow::ensure!(not_passed.is_empty(), "{}", not_passed.join("; "));
    }
    anyhow::ensure!(exited_ok, "forge test exited with an error");
    let suites = suites.context("forge test's stdout is not its JSON result")?;
    anyhow::ensure!(
        suites.values().any(|suite| !suite.test_results.is_empty()),
        "no test ran"
    );
    Ok(())
}

/// Each URL, from its scheme to whitespace, `)`, `"` or `'`, becomes `<url>`: an RPC URL can
/// carry an API key, and forge and anvil quote them in errors.
pub(crate) fn redact_urls(text: &str) -> String {
    let mut redacted = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(separator) = rest.find("://") {
        let start = rest[..separator]
            .char_indices()
            .rev()
            .find(|(_, c)| !(c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
            .map_or(0, |(at, c)| at + c.len_utf8());
        let end = rest[separator..]
            .find(|c: char| c.is_whitespace() || matches!(c, ')' | '"' | '\''))
            .map_or(rest.len(), |at| separator + at);
        redacted.push_str(&rest[..start]);
        redacted.push_str("<url>");
        rest = &rest[end..];
    }
    redacted.push_str(rest);
    redacted
}

/// The listed files missing under `l1_contracts`, whatever their envs: forge exits 0 on a
/// `--match-path` that matches nothing.
fn missing_fork_tests<'a>(l1_contracts: &Path, tests: &'a [ForkTest]) -> Vec<&'a str> {
    tests
        .iter()
        .map(|test| test.path.as_str())
        .filter(|path| !l1_contracts.join(path).is_file())
        .collect()
}

#[derive(Clone, Copy)]
pub(crate) struct ForkOrigin<'a> {
    pub url: &'a str,
    pub block: u64,
}

pub(crate) fn run_fork_tests(
    tests: &[ForkTest],
    env: &str,
    rpc_url: &str,
    origin: ForkOrigin<'_>,
    chains: &ReplayedChains,
    ecosystem_toml: &Path,
    checks_dir: &Path,
) -> anyhow::Result<()> {
    const FORK_URL: &str = "FORK_URL";
    let l1_contracts = paths::resolve_l1_contracts_path()?;
    let missing = missing_fork_tests(&l1_contracts, tests);
    anyhow::ensure!(
        missing.is_empty(),
        "fork_tests lists files that don't exist: {}",
        missing.join(", ")
    );
    fs::copy(ecosystem_toml, checks_dir.join("ecosystem.toml"))
        .context("copy ecosystem.toml into CHECKS_DIR")?;
    let exports = [
        ("L1_RPC_URL", rpc_url.to_string()),
        // For reads at FORK_BLOCK, which must not go to the Anvil: Anvil 1.5.1 serves a block
        // below its head holding a lock (`Backend::with_database_at`) while a task on its own
        // runtime fetches a miss, so concurrent reads there deadlock.
        (FORK_URL, origin.url.to_string()),
        ("UPGRADE_ENV", env.to_string()),
        ("FORK_BLOCK", origin.block.to_string()),
        ("REFERENCE_CHAIN_ID", chains.reference.to_string()),
        ("TEST_CHAIN_ID", chains.test.to_string()),
        ("CHECKS_DIR", checks_dir.display().to_string()),
    ];
    for (name, value) in &exports {
        // FORK_URL can carry an API key.
        let shown = if *name == FORK_URL {
            "<the --fork-url, not shown>"
        } else {
            value
        };
        logger::info(format!("{name}={shown}"));
    }
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

    // Forge pins `--fork-url` to the Anvil's head, where reads are safe; nothing may mine on
    // the Anvil while forge runs, or its reads fall below the head.
    let mut report = Report::default();
    for test in tests {
        if !test.runs_in(env) {
            logger::info(format!("fork test {} doesn't run in {env}", test.path));
            continue;
        }
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
            // Forge logs to stdout, at the default level a failed RPC read among it; with its log
            // off, stdout is the JSON result alone.
            .env("RUST_LOG", "off")
            .output()
            .with_context(|| format!("run forge test for {}", test.path))?;
        match fork_test_verdict(&String::from_utf8_lossy(&out.stdout), out.status.success()) {
            Ok(()) => report.ok(format!("fork test {}", test.path)),
            Err(error) => {
                logger::warn(redact_urls(&String::from_utf8_lossy(&out.stderr)));
                report.error(format!("{}: {error:#}", test.path));
            }
        }
    }
    report.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::consensus::transaction::Recovered;
    use alloy::consensus::{Signed, TxEnvelope, TxLegacy};
    use alloy::primitives::{Signature, TxKind};
    use alloy::providers::RootProvider;
    use alloy::rpc::client::RpcClient;
    use alloy::rpc::types::Log;
    use alloy::transports::mock::Asserter;

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

    /// The cut and stages from v34 stage's committed output (whose `upgrade_cut_data` is encoded
    /// like `chain_upgrade_diamond_cut`), with synthetic addresses.
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

    /// Two words, the least `try_parse_bytecode` accepts.
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

    fn deploy(salt: B256, init_code: &[u8]) -> (SafeTx, Address) {
        let tx = SafeTx {
            to: FACTORY,
            value: "0".to_string(),
            data: [salt.as_slice(), init_code].concat().into(),
        };
        (
            tx,
            compute_create2_address_evm(FACTORY, salt, keccak256(init_code)),
        )
    }

    fn publication() -> SafeTx {
        SafeTx {
            to: SUPPLIER,
            value: "0x0".to_string(),
            data: IBytecodesSupplierPublish::publishEraBytecodesCall {
                _bytecodes: vec![Bytes::from(vec![1u8; 32])],
            }
            .abi_encode()
            .into(),
        }
    }

    /// The facet with one constructor word.
    fn facet_init() -> Vec<u8> {
        [bytecode(1), vec![0x0a; 32]].concat()
    }

    /// The rules with each of `deployed` in the output and without code at the fork block.
    fn run(txs: &[SafeTx], deployed: &[Address]) -> (Vec<String>, Vec<Address>) {
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
        assert_eq!(found, [facet_address, checker_address]);
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
        assert!(found.is_empty());
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
        let stray = SafeTx {
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
        assert_eq!(found.len(), 1);
    }

    /// A command's bundles as `split_into_bundles` makes them from forge's broadcasts.
    fn bundle(target: Address, txs: &[(Address, &str, &str)]) -> SafeBundle {
        SafeBundle {
            target: format!("{target:#x}"),
            steps: vec!["chain upgrade".to_string()],
            txs: txs
                .iter()
                .map(|(to, value, data)| {
                    serde_json::json!({
                        "step": "chain upgrade",
                        "from": format!("{target:#x}"),
                        "to": format!("{to:#x}"),
                        "data": data,
                        "value": value,
                    })
                })
                .collect(),
        }
    }

    #[test]
    fn the_replay_sends_each_bundle_from_its_signer_as_written() {
        let (owner, admin) = (Address::repeat_byte(0xa2), Address::repeat_byte(0xa1));
        let notifier = Address::repeat_byte(0x5e);
        let bundles = [
            bundle(owner, &[(admin, "0", "0x0102"), (admin, "0", "0x03")]),
            bundle(notifier, &[(CTM, "0", "0x")]),
        ];
        let calls: Vec<_> = bundle_calls(&bundles)
            .unwrap()
            .into_iter()
            .map(|(from, tx)| (from, tx.to, tx.data.to_vec()))
            .collect();
        assert_eq!(
            calls,
            [
                (owner, admin, vec![1, 2]),
                (owner, admin, vec![3]),
                (notifier, CTM, vec![]),
            ]
        );
        let paying = [bundle(owner, &[(admin, "0x1", "0x")])];
        let error = bundle_calls(&paying).unwrap_err().to_string();
        assert!(error.ends_with("sends value 0x1"), "{error}");
        let mut unsigned = bundle(owner, &[(admin, "0", "0x")]);
        unsigned.target = String::new();
        assert!(bundle_calls(&[unsigned]).is_err());
    }

    #[test]
    fn reinforce_unfreeze_is_the_puhs_function() {
        let path = paths::resolve_l1_contracts_path()
            .unwrap()
            .join("scripts/abi/TestnetProtocolUpgradeHandler.json");
        let puh: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(
            puh["methodIdentifiers"]["reinforceUnfreeze()"],
            alloy::hex::encode(IProtocolUpgradeHandler::reinforceUnfreezeCall::SELECTOR)
        );
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

    /// Forge 1.5.1's stdout under `RUST_LOG=off` for a file that skips in `setUp`.
    const SKIPPED: &str = r#"{"test/foundry/fork/V34EraUpgrade.t.sol:V34EraUpgradeForkTest":{"duration":"244µs 916ns","test_results":{"setUp()":{"status":"Skipped","reason":"skipped: no CHECKS_DIR: protocol-ops' fork_tests run this on the fork it replayed the upgrade on","counterexample":null,"logs":[],"decoded_logs":[],"kind":{"Unit":{"gas":0}},"traces":[],"labeled_addresses":{},"duration":"0s","breakpoints":{},"gas_snapshots":{}}},"warnings":[]}}"#;

    /// `SKIPPED` with its one result's status and reason replaced.
    fn with_result(status: &str, reason: Option<&str>) -> String {
        let reason = reason.map_or("null".to_string(), |reason| format!("{reason:?}"));
        let skipped = r#""status":"Skipped","reason":"skipped: no CHECKS_DIR: protocol-ops' fork_tests run this on the fork it replayed the upgrade on""#;
        SKIPPED.replace(
            skipped,
            &format!(r#""status":"{status}","reason":{reason}"#),
        )
    }

    fn with_status(status: &str) -> String {
        with_result(status, None)
    }

    fn verdict(stdout: &str, exited_ok: bool) -> Result<(), String> {
        fork_test_verdict(stdout, exited_ok).map_err(|error| format!("{error:#}"))
    }

    #[test]
    fn a_fork_test_file_passes_only_if_every_test_passed() {
        assert_eq!(verdict(&with_status("Success"), true), Ok(()));
        let suite = "test/foundry/fork/V34EraUpgrade.t.sol:V34EraUpgradeForkTest";
        assert_eq!(
            verdict(&with_status("Failure"), false),
            Err(format!("{suite} setUp(): Failure"))
        );
        // Forge's reason comes along, without the URLs in it.
        let reason = "could not instantiate forked environment with provider \
            https://eth.example/v2/SOMEKEY: operation timed out";
        assert_eq!(
            verdict(&with_result("Failure", Some(reason)), false),
            Err(format!(
                "{suite} setUp(): Failure: could not instantiate forked environment with \
                 provider <url> operation timed out"
            ))
        );
        // A skip fails even where forge exits 0.
        assert_eq!(
            verdict(SKIPPED, true),
            Err(format!(
                "{suite} setUp(): Skipped: skipped: no CHECKS_DIR: protocol-ops' fork_tests run \
                 this on the fork it replayed the upgrade on"
            ))
        );
        // A failure beside a pass.
        let two = with_status("Success").replace(
            r#""test_results":{"#,
            r#""test_results":{"test_cap()":{"status":"Failure"},"#,
        );
        assert_eq!(
            verdict(&two, false),
            Err(format!("{suite} test_cap(): Failure"))
        );
    }

    #[test]
    fn a_result_the_verdict_does_not_know_fails() {
        // No test ran: no suite, or a suite without results.
        assert_eq!(verdict("{}", true), Err("no test ran".to_string()));
        let empty = r#"{"x.t.sol:X":{"test_results":{}}}"#;
        assert_eq!(verdict(empty, true), Err("no test ran".to_string()));
        // All passed, but forge exited with an error.
        assert_eq!(
            verdict(&with_status("Success"), false),
            Err("forge test exited with an error".to_string())
        );
        // Not the JSON alone: nothing, a log line before it, or another status.
        let logged = format!("2026-11-03T15:50:58Z ERROR sharedbackend: failed\n{SKIPPED}");
        for stdout in ["", logged.as_str(), &with_status("Ignored")] {
            let error = verdict(stdout, true).unwrap_err();
            assert!(
                error.starts_with("forge test's stdout is not its JSON result"),
                "{error}"
            );
        }
    }

    #[test]
    fn a_missing_fork_test_file_is_named() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir_all(root.path().join("test")).unwrap();
        fs::write(root.path().join("test/A.t.sol"), "").unwrap();
        let test = |path: &str| ForkTest {
            path: path.to_string(),
            envs: Some(vec!["mainnet".to_string()]),
        };
        let tests = [test("test/A.t.sol"), test("test/B.t.sol"), test("test")];
        // Whatever its envs; a directory is no file.
        assert_eq!(
            missing_fork_tests(root.path(), &tests),
            ["test/B.t.sol", "test"]
        );
    }

    #[test]
    fn urls_are_redacted() {
        let text = "Error: upstream (https://user:pw@eth.example/v2/SOMEKEY?k=1) failed; \
            ws://node:8546 'http://a.b/KEY2' \"https://c.d/KEY3\" plain";
        assert_eq!(
            redact_urls(text),
            "Error: upstream (<url>) failed; <url> '<url>' \"<url>\" plain"
        );
    }

    #[test]
    fn the_reference_chain_is_the_one_test_upgrade_chain_calls() {
        let call = |target: u8| GovernanceCall {
            target: Address::repeat_byte(target),
            value: U256::ZERO,
            data: vec![0xab],
        };
        assert_eq!(
            reference_diamond(&[call(0xd1), call(0xd1)]).unwrap(),
            Address::repeat_byte(0xd1)
        );
        for calls in [&[][..], &[call(0xd1), call(0xd2)][..]] {
            let error = reference_diamond(calls).unwrap_err();
            assert!(error.to_string().contains("must call one chain"), "{error}");
        }
    }

    const BRIDGEHUB: Address = Address::repeat_byte(0xb4);
    const DIAMOND: Address = Address::repeat_byte(0xd1);

    fn mocked(asserter: &Asserter) -> AlloyProvider {
        RootProvider::new(RpcClient::mocked(asserter.clone()))
    }

    /// `write_last_execute_input`'s error and file, on an RPC that answers
    /// `getTotalBatchesExecuted()` with 7, then with what `respond` pushes.
    async fn lookup(respond: impl FnOnce(&Asserter)) -> (Option<String>, Option<String>) {
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from(U256::from(7).to_be_bytes::<32>()));
        respond(&asserter);
        let fork = Fork {
            rpc_url: String::new(),
            provider: mocked(&asserter),
        };
        let facts = Facts {
            ctm: CTM,
            ctm_owner: Address::repeat_byte(0xa0),
            server_notifier: Address::repeat_byte(0x5e),
            bridgehub: BRIDGEHUB,
            diamond: DIAMOND,
            chain_id: 312,
            chain_admin: Address::repeat_byte(0xa1),
            chain_admin_owner: Address::repeat_byte(0xa2),
        };
        let work_dir = tempfile::tempdir().unwrap();
        // Below EXECUTE_LOG_WINDOW: one eth_getLogs request.
        let error = write_last_execute_input(&fork, &facts, 500, work_dir.path())
            .await
            .err()
            .map(|error| format!("{error:#}"));
        let file = fs::read_to_string(work_dir.path().join(LAST_EXECUTE_INPUT_FILE)).ok();
        (error, file)
    }

    #[tokio::test]
    async fn a_failed_execute_log_lookup_fails_and_writes_no_file() {
        // An idle chain, or a log older than the search.
        let (error, file) = lookup(|rpc| rpc.push_success(&Vec::<Log>::new())).await;
        assert_eq!(file, None);
        assert_eq!(
            error.unwrap(),
            "0 BlockExecution logs for batch 7 in the 501 blocks up to 500"
        );
        // An RPC error; `CheckFailures` redacts its URL.
        let (error, file) = lookup(|rpc| rpc.push_failure_msg("429 Too Many Requests")).await;
        assert_eq!(file, None);
        assert_eq!(
            error.unwrap(),
            "eth_getLogs: server returned an error response: error code -32603: \
             429 Too Many Requests"
        );
    }

    #[tokio::test]
    async fn the_execute_lookup_writes_the_transactions_input() {
        let hash = B256::repeat_byte(0xe7);
        let log = Log {
            inner: alloy::primitives::Log::new_unchecked(
                DIAMOND,
                vec![
                    keccak256("BlockExecution(uint256,bytes32,bytes32)"),
                    B256::from(U256::from(7)),
                ],
                Bytes::new(),
            ),
            transaction_hash: Some(hash),
            ..Default::default()
        };
        let execute = TxLegacy {
            to: TxKind::Call(Address::repeat_byte(0x7e)),
            input: Bytes::from(vec![0xab, 0xcd]),
            ..Default::default()
        };
        let signed = Signed::new_unchecked(execute, Signature::test_signature(), hash);
        let tx = alloy::rpc::types::Transaction {
            inner: Recovered::new_unchecked(TxEnvelope::Legacy(signed), Address::repeat_byte(0xee)),
            block_hash: None,
            block_number: None,
            transaction_index: None,
            effective_gas_price: None,
            block_timestamp: None,
        };
        let (error, file) = lookup(|rpc| {
            rpc.push_success(&vec![log]);
            rpc.push_success(&tx);
        })
        .await;
        assert_eq!((error, file.as_deref()), (None, Some("0xabcd")));
    }

    #[tokio::test]
    async fn the_ctm_must_be_the_bridgehubs_for_the_reference_chain() {
        let asserter = Asserter::new();
        let provider = mocked(&asserter);
        let verdict = || async {
            let mut report = Report::default();
            check_chain_ctm(&provider, BRIDGEHUB, 312, CTM, &mut report).await?;
            report.finish()
        };
        let answer = |ctm: Address| asserter.push_success(&Bytes::from(ctm.into_word().to_vec()));
        answer(CTM);
        assert!(verdict().await.is_ok());
        // A self-consistent CTM and supplier of another ecosystem.
        let other = Address::repeat_byte(0xc8);
        answer(other);
        assert_eq!(
            verdict().await.unwrap_err().to_string(),
            format!(
                "the bridgehub's chainTypeManager(312) = state_transition.chain_type_manager_proxy: \
                 expected {CTM}, got {other}"
            )
        );
        // A failed read names the call.
        asserter.push_failure_msg("upstream down");
        let error = verdict().await.unwrap_err();
        assert!(
            format!("{error:#}").starts_with(&format!("{BRIDGEHUB}.chainTypeManager(312): ")),
            "{error:#}"
        );
    }

    #[test]
    fn the_execute_log_search_walks_back_in_adjacent_windows() {
        let span =
            |windows: &[(u64, u64)]| windows.iter().map(|(from, to)| to - from + 1).sum::<u64>();
        // testnet3's gate fork block: 50 full windows, newest first, without gaps or overlap.
        let windows = execute_log_windows(12_018_509);
        assert_eq!(windows.len(), 50);
        assert_eq!(windows[0], (12_017_510, 12_018_509));
        assert_eq!(windows[49], (11_968_510, 11_969_509));
        assert_eq!(span(&windows), EXECUTE_LOG_SPAN);
        for pair in windows.windows(2) {
            assert_eq!(pair[1].1 + 1, pair[0].0, "{pair:?}");
        }
        assert!(windows
            .iter()
            .all(|(from, to)| to - from + 1 == EXECUTE_LOG_WINDOW));
        // Below EXECUTE_LOG_SPAN the search stops at block 0, the last window cut short.
        assert_eq!(execute_log_windows(1_234), vec![(235, 1_234), (0, 234)]);
        assert_eq!(span(&execute_log_windows(49_999)), EXECUTE_LOG_SPAN);
        assert_eq!(execute_log_windows(49_999)[49], (0, 999));
        assert_eq!(execute_log_windows(0), vec![(0, 0)]);
    }
}
