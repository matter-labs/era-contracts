//! Built-in checks of a verifier-only upgrade (`prepare = "prepare-all"`, `verifier_only = true`,
//! see `common::upgrade_descriptor`), run by the generate / replay / deploy pipeline in place of
//! the `verify_fork` / `verify_chain` commands a forge-script upgrade declares.
//!
//! - [`check_chain`], read-only against the chain the deploy bundle was broadcast to: the four
//!   CREATE2 contracts of `ecosystem.toml` exist, the verifier carries the new VK in the env's
//!   flavour, and the stage validator and the governance timer are wired to this CTM and its
//!   owner. Before the governance stages ran the CTM must still be on the old version, after
//!   them on the new one with the new verifier.
//! - [`check_fork`], on a fork the deploy bundle was replayed on: the same, then governance
//!   stages 0/1/2 of `[governance_calls]` sent from the CTM's owner (the `Governance` contract or
//!   the ProtocolUpgradeHandler, impersonated), the committed per-chain bundles of
//!   `output/<env>/chain-upgrades/` when there are any, and the test chain creation, asserting
//!   the resulting L1 state.
//!
//! [`check_execution_matches`] ties the transactions whoever executes sends by hand
//! (`output/<env>/execution.json`) to those same `[governance_calls]`.

use std::fmt::Debug;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::network::TransactionBuilder;
use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::rpc::types::TransactionRequest;
use alloy::sol_types::SolCall;
use anyhow::Context;

use crate::common::anvil::set_balance;
use crate::common::ethereum::get_provider;
use crate::common::governance_calls::{decode_calls, GovernanceCall};
use crate::common::logger;

alloy::sol! {
    #[sol(rpc)]
    interface IVerifierOnlyCtm {
        function owner() external view returns (address);
        function BRIDGE_HUB() external view returns (address);
        function protocolVersion() external view returns (uint256);
        function protocolVersionVerifier(uint256 _protocolVersion) external view returns (address);
        function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool);
        function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);
        function initialCutHash() external view returns (bytes32);
        function initialForceDeploymentHash() external view returns (bytes32);
        function newChainCreationParamsBlock(uint256 _protocolVersion) external view returns (uint256);
        function defaultUpgrade() external view returns (address);
    }

    #[sol(rpc)]
    interface IVerifierOnlyVerifier {
        function verificationKeyHash() external view returns (bytes32);
        function PLONK_VERIFIER() external view returns (address);
        function IS_TESTNET_VERIFIER() external view returns (bool);
    }

    #[sol(rpc)]
    interface IVerifierOnlyStageValidator {
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function NEW_PROTOCOL_VERSION() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IVerifierOnlyTimer {
        function TIMER_GOVERNANCE() external view returns (address);
        function INITIAL_DELAY() external view returns (uint256);
        function deadline() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IVerifierOnlyBridgehub {
        function chainAssetHandler() external view returns (address);
        function getZKChain(uint256 _chainId) external view returns (address);
    }

    #[sol(rpc)]
    interface IVerifierOnlyChainAssetHandler {
        function migrationPaused() external view returns (bool);
    }

    #[sol(rpc)]
    interface IVerifierOnlyChain {
        function getProtocolVersion() external view returns (uint256);
        function getVerifier() external view returns (address);
        function facetAddresses() external view returns (address[] memory);
        function getTotalBatchesCommitted() external view returns (uint256);
        function getTotalBatchesExecuted() external view returns (uint256);
    }

    /// The two ways the governance stages are executed by hand.
    interface IVerifierOnlyExecution {
        struct Call {
            address target;
            uint256 value;
            bytes data;
        }
        struct Operation {
            Call[] calls;
            bytes32 predecessor;
            bytes32 salt;
        }
        /// `Governance.execute`, once per stage.
        function execute(Operation calldata _operation) external payable;
        /// `EmergencyUpgradeBoard.executeEmergencyUpgrade`, stages 0-2 at once.
        function executeEmergencyUpgrade(
            Call[] calldata _calls,
            bytes32 _salt,
            bytes calldata _guardiansSignatures,
            bytes calldata _securityCouncilSignatures,
            bytes calldata _zkFoundationSignatures
        ) external;
    }
}

/// `NotAllBatchesExecuted()`: a chain with committed but unexecuted batches refuses the cut.
const NOT_ALL_BATCHES_EXECUTED: &str = "f9ba09d6";

/// What the checks read from the prepare's `ecosystem.toml` and the upgrade's `<env>.toml` input.
struct Expected {
    ctm: Address,
    verifier: Address,
    verifier_plonk: Address,
    stage_validator: Address,
    timer: Address,
    old_version: U256,
    new_version: U256,
    vk_hash: B256,
    default_upgrade: Address,
    testnet_verifier: bool,
    timer_initial_delay: U256,
    ecosystem: toml::Table,
}

impl Expected {
    fn load(ecosystem_toml: &Path, upgrade_input: &Path) -> anyhow::Result<Self> {
        let ecosystem = read_toml(ecosystem_toml)?;
        let input = read_toml(upgrade_input)?;
        Ok(Self {
            ctm: address(&ecosystem, "state_transition.chain_type_manager_proxy")?,
            verifier: address(&ecosystem, "state_transition.verifier_addr")?,
            verifier_plonk: address(&ecosystem, "state_transition.verifier_plonk_addr")?,
            stage_validator: address(&ecosystem, "deployed_addresses.upgrade_stage_validator")?,
            timer: address(&ecosystem, "deployed_addresses.l1_governance_upgrade_timer")?,
            old_version: uint(&ecosystem, "contracts_config.old_protocol_version")?,
            new_version: uint(&ecosystem, "contracts_config.new_protocol_version")?,
            vk_hash: string(&ecosystem, "verification_key.new_vk_hash")?
                .parse()
                .context("verification_key.new_vk_hash")?,
            default_upgrade: address(
                &ecosystem,
                "state_transition.ctm_stored_default_upgrade_addr",
            )?,
            testnet_verifier: lookup(&input, "testnet_verifier")?
                .as_bool()
                .with_context(|| {
                    format!(
                        "{}: testnet_verifier is not a bool",
                        upgrade_input.display()
                    )
                })?,
            timer_initial_delay: uint(&input, "governance_upgrade_timer_initial_delay")?,
            ecosystem,
        })
    }
}

/// Collects every failed assertion, so one run reports them all.
#[derive(Default)]
struct Report {
    failures: Vec<String>,
}

impl Report {
    fn check<T: PartialEq + Debug>(&mut self, what: &str, actual: T, expected: T) {
        if actual == expected {
            logger::info(format!("  OK   {what}"));
        } else {
            self.fail(format!("{what}: expected {expected:?}, got {actual:?}"));
        }
    }

    fn fail(&mut self, message: String) {
        logger::warn(format!("FAIL: {message}"));
        self.failures.push(message);
    }

    fn finish(self, what: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.failures.is_empty(),
            "{what} failed:\n  {}",
            self.failures.join("\n  ")
        );
        logger::success(format!("{what} passed"));
        Ok(())
    }
}

/// Read-only check of the deployments on the chain the bundle was broadcast to.
pub async fn check_chain(
    rpc_url: &str,
    ecosystem_toml: &Path,
    upgrade_input: &Path,
) -> anyhow::Result<()> {
    logger::step("verifier-only deployment check (read-only)");
    let expected = Expected::load(ecosystem_toml, upgrade_input)?;
    let mut report = Report::default();
    check_deployments(rpc_url, &expected, &mut report).await?;
    let ctm = IVerifierOnlyCtm::new(expected.ctm, get_provider(rpc_url)?);
    // The governance stages may or may not have run; either is a valid state for the deployment.
    let version = ctm.protocolVersion().call().await?;
    if version == expected.new_version {
        logger::info("CTM is on the new version: the governance stages have run");
        report.check(
            "CTM verifier for the new version",
            ctm.protocolVersionVerifier(expected.new_version)
                .call()
                .await?,
            expected.verifier,
        );
    } else {
        report.check(
            "CTM still on the old version (governance not run yet)",
            version,
            expected.old_version,
        );
    }
    report.finish("verifier-only deployment check")
}

/// The upgrade rehearsed on a fork on which the deploy bundle was replayed. Sends impersonated
/// transactions, so it leaves the fork upgraded.
pub async fn check_fork(
    rpc_url: &str,
    ecosystem_toml: &Path,
    upgrade_input: &Path,
    chain_bundles: &Path,
) -> anyhow::Result<()> {
    logger::step("verifier-only upgrade rehearsal");
    let expected = Expected::load(ecosystem_toml, upgrade_input)?;
    let provider = get_provider(rpc_url)?;
    let ctm = IVerifierOnlyCtm::new(expected.ctm, provider.clone());
    let mut report = Report::default();

    // ── 1. deployments, before governance
    check_deployments(rpc_url, &expected, &mut report).await?;
    report.check(
        "CTM on the old version before governance",
        ctm.protocolVersion().call().await?,
        expected.old_version,
    );
    report.check(
        "CTM stored default upgrade unchanged",
        ctm.defaultUpgrade().call().await?,
        expected.default_upgrade,
    );
    let initial_cut_hash = ctm.initialCutHash().call().await?;
    let force_deployment_hash = ctm.initialForceDeploymentHash().call().await?;

    // ── 2. governance stages 0/1/2, from the CTM's owner
    let owner = ctm.owner().call().await?;
    for stage in 0..3 {
        let calls = decode_calls(string(
            &expected.ecosystem,
            &format!("governance_calls.stage{stage}_calls"),
        )?)
        .with_context(|| format!("governance_calls.stage{stage}_calls"))?;
        for (i, call) in calls.iter().enumerate() {
            let what = format!("stage {stage} call {} to {:#x}", i + 1, call.target);
            match send(rpc_url, owner, call.target, call.value, call.data.clone()).await {
                Ok(()) => logger::info(format!("  OK   {what} (as the CTM owner {owner:#x})")),
                Err(error) => report.fail(format!("{what}: {error:#}")),
            }
        }
    }
    let timer = IVerifierOnlyTimer::new(expected.timer, provider.clone());
    report.check(
        "upgrade timer started",
        timer.deadline().call().await? != U256::ZERO,
        true,
    );
    report.check(
        "CTM protocolVersion",
        ctm.protocolVersion().call().await?,
        expected.new_version,
    );
    report.check(
        "CTM verifier for the new version",
        ctm.protocolVersionVerifier(expected.new_version)
            .call()
            .await?,
        expected.verifier,
    );
    let cut = hex_bytes(string(&expected.ecosystem, "chain_upgrade_diamond_cut")?)
        .context("chain_upgrade_diamond_cut")?;
    report.check(
        "CTM stored cut = chain_upgrade_diamond_cut",
        ctm.upgradeCutHash(expected.old_version).call().await?,
        alloy::primitives::keccak256(&cut),
    );
    report.check(
        "old version still active",
        ctm.protocolVersionIsActive(expected.old_version)
            .call()
            .await?,
        true,
    );
    report.check(
        "creation cut unchanged",
        ctm.initialCutHash().call().await?,
        initial_cut_hash,
    );
    report.check(
        "force deployments unchanged",
        ctm.initialForceDeploymentHash().call().await?,
        force_deployment_hash,
    );
    report.check(
        "creation params carried to the new version",
        ctm.newChainCreationParamsBlock(expected.new_version)
            .call()
            .await?,
        ctm.newChainCreationParamsBlock(expected.old_version)
            .call()
            .await?,
    );
    let bridgehub = IVerifierOnlyBridgehub::new(ctm.BRIDGE_HUB().call().await?, provider.clone());
    let chain_asset_handler = IVerifierOnlyChainAssetHandler::new(
        bridgehub.chainAssetHandler().call().await?,
        provider.clone(),
    );
    report.check(
        "migrations unpaused again",
        chain_asset_handler.migrationPaused().call().await?,
        false,
    );

    // ── 3. the committed per-chain bundles
    check_chain_bundles(rpc_url, &expected, chain_bundles, &mut report).await?;

    // ── 4. a chain created after the upgrade
    let caller = address(
        &expected.ecosystem,
        "test_upgrade_calls.test_create_chain_zkos_caller",
    )?;
    let calls = decode_calls(string(
        &expected.ecosystem,
        "test_upgrade_calls.test_create_chain_zkos",
    )?)
    .context("test_upgrade_calls.test_create_chain_zkos")?;
    anyhow::ensure!(
        calls.len() == 1 && calls[0].data.len() >= 36,
        "test_create_chain_zkos must be one createNewChain call"
    );
    let chain_id = U256::from_be_slice(&calls[0].data[4..36]);
    match send(
        rpc_url,
        caller,
        calls[0].target,
        calls[0].value,
        calls[0].data.clone(),
    )
    .await
    {
        Ok(()) => {
            logger::info(format!("  OK   test createNewChain({chain_id})"));
            let chain = IVerifierOnlyChain::new(
                bridgehub.getZKChain(chain_id).call().await?,
                provider.clone(),
            );
            report.check(
                "new chain protocolVersion",
                chain.getProtocolVersion().call().await?,
                expected.new_version,
            );
            report.check(
                "new chain verifier",
                chain.getVerifier().call().await?,
                expected.verifier,
            );
        }
        Err(error) => report.fail(format!("test chain creation: {error:#}")),
    }

    report.finish("verifier-only upgrade rehearsal")
}

/// The four contracts exist and are wired as the upgrade expects.
async fn check_deployments(
    rpc_url: &str,
    expected: &Expected,
    report: &mut Report,
) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    for (name, address) in [
        ("ZKsyncOSVerifierPlonk", expected.verifier_plonk),
        ("verifier", expected.verifier),
        ("UpgradeStageValidator", expected.stage_validator),
        ("GovernanceUpgradeTimer", expected.timer),
    ] {
        let code = provider
            .get_code_at(address)
            .await
            .with_context(|| format!("eth_getCode({address:#x})"))?;
        report.check(
            &format!("{name} deployed at {address:#x}"),
            !code.is_empty(),
            true,
        );
    }
    let verifier = IVerifierOnlyVerifier::new(expected.verifier, provider.clone());
    report.check(
        "verifier VK",
        verifier.verificationKeyHash().call().await?,
        expected.vk_hash,
    );
    report.check(
        "verifier wraps verifier_plonk",
        verifier.PLONK_VERIFIER().call().await?,
        expected.verifier_plonk,
    );
    report.check(
        "verifier flavour (testnet_verifier)",
        verifier.IS_TESTNET_VERIFIER().call().await?,
        expected.testnet_verifier,
    );
    let validator = IVerifierOnlyStageValidator::new(expected.stage_validator, provider.clone());
    report.check(
        "stage validator CTM",
        validator.CHAIN_TYPE_MANAGER().call().await?,
        expected.ctm,
    );
    report.check(
        "stage validator version",
        validator.NEW_PROTOCOL_VERSION().call().await?,
        expected.new_version,
    );
    let timer = IVerifierOnlyTimer::new(expected.timer, provider.clone());
    let ctm = IVerifierOnlyCtm::new(expected.ctm, provider);
    report.check(
        "timer governance = CTM owner",
        timer.TIMER_GOVERNANCE().call().await?,
        ctm.owner().call().await?,
    );
    report.check(
        "timer initial delay",
        timer.INITIAL_DELAY().call().await?,
        expected.timer_initial_delay,
    );
    Ok(())
}

/// Per chain with bundles under `chain_bundles/<chain id>/`: `01_*` (`setUpgradeTimestamp`) then
/// `02_*` (the cut), both through the chain's ChainAdmin from its owner. A chain with committed but
/// unexecuted batches must refuse the cut (`NotAllBatchesExecuted`); every other chain must upgrade.
async fn check_chain_bundles(
    rpc_url: &str,
    expected: &Expected,
    chain_bundles: &Path,
    report: &mut Report,
) -> anyhow::Result<()> {
    let chain_ids = committed_chain_ids(chain_bundles)?;
    if chain_ids.is_empty() {
        logger::info(format!(
            "No per-chain bundles in {} yet (generate-chain-upgrade-calldata.yaml writes them): chain step skipped",
            chain_bundles.display()
        ));
        return Ok(());
    }
    let provider = get_provider(rpc_url)?;
    for chain_id in chain_ids {
        let entry = |key: &str| format!("chain_upgrades.{chain_id}.{key}");
        let (Ok(chain), Ok(admin), Ok(owner)) = (
            address(&expected.ecosystem, &entry("chain")),
            address(&expected.ecosystem, &entry("chain_admin")),
            address(&expected.ecosystem, &entry("chain_admin_owner")),
        ) else {
            report.fail(format!(
                "chain {chain_id} has bundles but no [chain_upgrades.{chain_id}] in the ecosystem toml"
            ));
            continue;
        };
        let dir = chain_bundles.join(chain_id.to_string());
        let (timestamp_to, timestamp_data) = bundle_tx(&dir, "01_")?;
        let (cut_to, cut_data) = bundle_tx(&dir, "02_")?;
        report.check(
            &format!("chain {chain_id} bundles go to its ChainAdmin"),
            (timestamp_to, cut_to),
            (admin, admin),
        );
        if let Ok(calldata) = string(&expected.ecosystem, &entry("chain_admin_calldata")) {
            report.check(
                &format!("chain {chain_id} cut bundle = chain_admin_calldata"),
                cut_data.clone(),
                hex_bytes(calldata)?,
            );
        }
        let zk_chain = IVerifierOnlyChain::new(chain, provider.clone());
        let facets_before = zk_chain.facetAddresses().call().await?;
        let committed = zk_chain.getTotalBatchesCommitted().call().await?;
        let executed = zk_chain.getTotalBatchesExecuted().call().await?;
        if let Err(error) = send(rpc_url, owner, admin, U256::ZERO, timestamp_data).await {
            report.fail(format!("chain {chain_id} setUpgradeTimestamp: {error:#}"));
            continue;
        }
        if committed == executed {
            match send(rpc_url, owner, admin, U256::ZERO, cut_data).await {
                Ok(()) => {
                    logger::info(format!(
                        "  OK   chain {chain_id} upgraded (batches {executed}/{committed} executed)"
                    ));
                    report.check(
                        &format!("chain {chain_id} protocolVersion"),
                        zk_chain.getProtocolVersion().call().await?,
                        expected.new_version,
                    );
                    report.check(
                        &format!("chain {chain_id} verifier"),
                        zk_chain.getVerifier().call().await?,
                        expected.verifier,
                    );
                    report.check(
                        &format!("chain {chain_id} facets unchanged"),
                        zk_chain.facetAddresses().call().await?,
                        facets_before,
                    );
                }
                Err(error) => report.fail(format!("chain {chain_id} upgrade: {error:#}")),
            }
        } else {
            let request = TransactionRequest::default()
                .with_from(owner)
                .with_to(admin)
                .with_input(cut_data);
            match provider.call(request).await {
                Err(error) if format!("{error:?}").contains(NOT_ALL_BATCHES_EXECUTED) => {
                    logger::info(format!(
                        "  OK   chain {chain_id} (batches {executed}/{committed} executed) refuses the cut with NotAllBatchesExecuted"
                    ));
                }
                other => report.fail(format!(
                    "chain {chain_id} (batches {executed}/{committed} executed): expected NotAllBatchesExecuted, got {other:?}"
                )),
            }
            report.check(
                &format!("chain {chain_id} still on the old version"),
                zk_chain.getProtocolVersion().call().await?,
                expected.old_version,
            );
        }
    }
    Ok(())
}

/// The numeric subdirectories of `chain_bundles`, sorted.
fn committed_chain_ids(chain_bundles: &Path) -> anyhow::Result<Vec<u64>> {
    if !chain_bundles.is_dir() {
        return Ok(Vec::new());
    }
    let mut ids = Vec::new();
    for entry in
        fs::read_dir(chain_bundles).with_context(|| format!("read {}", chain_bundles.display()))?
    {
        let entry = entry?;
        if entry.path().is_dir() {
            if let Some(id) = entry.file_name().to_str().and_then(|n| n.parse().ok()) {
                ids.push(id);
            }
        }
    }
    ids.sort_unstable();
    Ok(ids)
}

/// The single transaction of the `<prefix>*.safe.json` bundle in `dir`.
fn bundle_tx(dir: &Path, prefix: &str) -> anyhow::Result<(Address, Bytes)> {
    let path: PathBuf = fs::read_dir(dir)
        .with_context(|| format!("read {}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .find(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(prefix) && n.ends_with(".safe.json"))
        })
        .with_context(|| format!("no {prefix}*.safe.json in {}", dir.display()))?;
    let bundle: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?,
    )
    .with_context(|| format!("parse {}", path.display()))?;
    let txs = bundle["transactions"]
        .as_array()
        .with_context(|| format!("{}: no transactions", path.display()))?;
    anyhow::ensure!(
        txs.len() == 1,
        "{}: expected one transaction",
        path.display()
    );
    let to = txs[0]["to"]
        .as_str()
        .with_context(|| format!("{}: no `to`", path.display()))?
        .parse()
        .with_context(|| format!("{}: `to`", path.display()))?;
    let data = hex_bytes(
        txs[0]["data"]
            .as_str()
            .with_context(|| format!("{}: no `data`", path.display()))?,
    )?;
    Ok((to, data))
}

/// The transactions whoever executes sends by hand (`source`: a list of transactions, or an object
/// with a `transactions` list) carry exactly stages 0-2 of `[governance_calls]`, in order: the
/// `Governance.execute` operations, or the emergency proposal's calls.
pub fn check_execution_matches(source: &Path, ecosystem_toml: &Path) -> anyhow::Result<()> {
    let ecosystem = read_toml(ecosystem_toml)?;
    let mut expected = Vec::new();
    for stage in 0..3 {
        expected.extend(
            decode_calls(string(
                &ecosystem,
                &format!("governance_calls.stage{stage}_calls"),
            )?)
            .with_context(|| format!("governance_calls.stage{stage}_calls"))?,
        );
    }
    let json: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(source).with_context(|| format!("read {}", source.display()))?,
    )
    .with_context(|| format!("parse {}", source.display()))?;
    let txs = json
        .as_array()
        .or_else(|| json["transactions"].as_array())
        .with_context(|| format!("{}: no transactions", source.display()))?;
    let mut executed = Vec::new();
    let mut executions = 0;
    for tx in txs {
        let data = hex_bytes(tx["data"].as_str().unwrap_or_default())?;
        let calls = if let Ok(call) = IVerifierOnlyExecution::executeCall::abi_decode(&data) {
            call._operation.calls
        } else if let Ok(call) =
            IVerifierOnlyExecution::executeEmergencyUpgradeCall::abi_decode(&data)
        {
            call._calls
        } else {
            continue;
        };
        executions += 1;
        executed.extend(calls.into_iter().map(|c| GovernanceCall {
            target: c.target,
            value: c.value,
            data: c.data.to_vec(),
        }));
    }
    anyhow::ensure!(
        executions > 0,
        "{} executes nothing: no Governance.execute or executeEmergencyUpgrade transaction",
        source.display()
    );
    let key = |calls: &[GovernanceCall]| -> Vec<(Address, U256, Vec<u8>)> {
        calls
            .iter()
            .map(|c| (c.target, c.value, c.data.clone()))
            .collect()
    };
    anyhow::ensure!(
        key(&executed) == key(&expected),
        "{} executes {} call(s) that differ from the {} of [governance_calls] stages 0-2",
        source.display(),
        executed.len(),
        expected.len()
    );
    logger::success(format!(
        "{} executes exactly [governance_calls] stages 0-2 ({} calls)",
        source.display(),
        expected.len()
    ));
    Ok(())
}

/// Send `data` from `from` (impersonated, funded) and fail on a revert.
async fn send(
    rpc_url: &str,
    from: Address,
    to: Address,
    value: U256,
    data: impl Into<Bytes>,
) -> anyhow::Result<()> {
    set_balance(rpc_url, from).await?;
    let request = TransactionRequest::default()
        .with_from(from)
        .with_to(to)
        .with_value(value)
        .with_input(data.into());
    let receipt = get_provider(rpc_url)?
        .send_transaction(request)
        .await
        .context("rejected")?
        .get_receipt()
        .await
        .context("no receipt")?;
    anyhow::ensure!(receipt.status(), "reverted");
    Ok(())
}

fn read_toml(path: &Path) -> anyhow::Result<toml::Table> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))
}

fn lookup<'a>(table: &'a toml::Table, path: &str) -> anyhow::Result<&'a toml::Value> {
    let mut keys = path.split('.');
    let first = keys.next().unwrap_or_default();
    let mut value = table
        .get(first)
        .with_context(|| format!("{path} missing"))?;
    for key in keys {
        value = value.get(key).with_context(|| format!("{path} missing"))?;
    }
    Ok(value)
}

fn string<'a>(table: &'a toml::Table, path: &str) -> anyhow::Result<&'a str> {
    lookup(table, path)?
        .as_str()
        .with_context(|| format!("{path} is not a string"))
}

fn address(table: &toml::Table, path: &str) -> anyhow::Result<Address> {
    string(table, path)?
        .parse()
        .with_context(|| format!("{path} is not an address"))
}

fn uint(table: &toml::Table, path: &str) -> anyhow::Result<U256> {
    match lookup(table, path)? {
        toml::Value::Integer(n) => Ok(U256::from(
            u64::try_from(*n).with_context(|| format!("{path} is negative"))?,
        )),
        toml::Value::String(s) => s.parse().with_context(|| format!("{path} is not a number")),
        _ => anyhow::bail!("{path} is not a number"),
    }
}

fn hex_bytes(hex_str: &str) -> anyhow::Result<Bytes> {
    hex_str
        .parse()
        .with_context(|| format!("not hex: {hex_str:.20}…"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::governance_calls::encode_calls;

    fn call(target: u8, data: &[u8]) -> GovernanceCall {
        GovernanceCall {
            target: Address::with_last_byte(target),
            value: U256::ZERO,
            data: data.to_vec(),
        }
    }

    fn sol(calls: &[GovernanceCall]) -> Vec<IVerifierOnlyExecution::Call> {
        calls
            .iter()
            .map(|c| IVerifierOnlyExecution::Call {
                target: c.target,
                value: c.value,
                data: c.data.clone().into(),
            })
            .collect()
    }

    /// An ecosystem toml with three stages, and the files that execute them.
    fn fixture(dir: &Path, stages: &[Vec<GovernanceCall>; 3]) -> PathBuf {
        let mut toml = String::from("[governance_calls]\n");
        for (i, calls) in stages.iter().enumerate() {
            toml += &format!(
                "stage{i}_calls = \"0x{}\"\n",
                alloy::hex::encode(encode_calls(calls))
            );
        }
        let path = dir.join("ecosystem.toml");
        fs::write(&path, toml).unwrap();
        path
    }

    fn write_json(dir: &Path, name: &str, value: serde_json::Value) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, value.to_string()).unwrap();
        path
    }

    #[test]
    fn execution_must_carry_exactly_the_governance_calls() {
        let dir = tempfile::tempdir().unwrap();
        let stages = [
            vec![call(1, b"a")],
            vec![call(2, b"b"), call(3, b"c")],
            vec![],
        ];
        let ecosystem = fixture(dir.path(), &stages);
        let all: Vec<_> = stages.iter().flatten().cloned().collect();

        // A ProtocolUpgradeHandler env: one emergency proposal after approveHash txs.
        let emergency = |calls: &[GovernanceCall]| {
            format!(
                "0x{}",
                alloy::hex::encode(
                    IVerifierOnlyExecution::executeEmergencyUpgradeCall {
                        _calls: sol(calls),
                        _salt: B256::ZERO,
                        _guardiansSignatures: Bytes::new(),
                        _securityCouncilSignatures: Bytes::new(),
                        _zkFoundationSignatures: Bytes::new(),
                    }
                    .abi_encode()
                )
            )
        };
        let good = write_json(
            dir.path(),
            "board.json",
            serde_json::json!({"transactions": [{"data": "0x1234"}, {"data": emergency(&all)}]}),
        );
        check_execution_matches(&good, &ecosystem).unwrap();
        let bad = write_json(
            dir.path(),
            "board-bad.json",
            serde_json::json!({"transactions": [{"data": emergency(&all[..2])}]}),
        );
        assert!(check_execution_matches(&bad, &ecosystem).is_err());

        // A Governance env: schedule + execute per stage.
        let execute = |calls: &[GovernanceCall]| {
            format!(
                "0x{}",
                alloy::hex::encode(
                    IVerifierOnlyExecution::executeCall {
                        _operation: IVerifierOnlyExecution::Operation {
                            calls: sol(calls),
                            predecessor: B256::ZERO,
                            salt: B256::ZERO,
                        },
                    }
                    .abi_encode()
                )
            )
        };
        let txs: Vec<_> = stages
            .iter()
            .flat_map(|calls| {
                [
                    serde_json::json!({"data": "0xabcdef"}),
                    serde_json::json!({"data": execute(calls)}),
                ]
            })
            .collect();
        let governance = write_json(dir.path(), "gov.json", serde_json::Value::Array(txs));
        check_execution_matches(&governance, &ecosystem).unwrap();

        let nothing = write_json(dir.path(), "none.json", serde_json::json!([{"data": "0x"}]));
        assert!(check_execution_matches(&nothing, &ecosystem).is_err());
    }

    #[test]
    fn reads_chain_bundles() {
        let dir = tempfile::tempdir().unwrap();
        assert!(committed_chain_ids(&dir.path().join("missing"))
            .unwrap()
            .is_empty());
        for id in ["27271", "2727", "README.md"] {
            fs::create_dir_all(dir.path().join(id)).unwrap();
        }
        assert_eq!(committed_chain_ids(dir.path()).unwrap(), vec![2727, 27271]);
        let target = Address::with_last_byte(7);
        write_json(
            &dir.path().join("2727"),
            "02_chain.upgrade_0x1.safe.json",
            serde_json::json!({"transactions": [{"to": format!("{target:#x}"), "data": "0xbeef"}]}),
        );
        let (to, data) = bundle_tx(&dir.path().join("2727"), "02_").unwrap();
        assert_eq!((to, data.to_vec()), (target, vec![0xbe, 0xef]));
        assert!(bundle_tx(&dir.path().join("2727"), "01_").is_err());
    }
}
