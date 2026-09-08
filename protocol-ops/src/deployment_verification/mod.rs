//! Verifies a *deployed* ecosystem against a local build of the contracts.
//!
//! Where `upgrade_verification` checks an upgrade against the artifacts that
//! produced it, this tree starts from a single Bridgehub address and asks a
//! different question: is what is live on L1 the code and the configuration
//! this checkout describes, and is anybody holding a role they should not?
//!
//! Nothing is taken from a deployment output file — every address is
//! discovered on chain, so a run against an ecosystem somebody else deployed
//! works exactly the same as a run against your own.

pub mod artifact_index;
pub mod chain_creation;
pub mod contracts;
pub mod discovery;
pub mod roles;

use std::collections::HashSet;
use std::path::PathBuf;

use alloy::primitives::{keccak256, Address, FixedBytes, U256};
use alloy::providers::Provider;
use alloy::rpc::types::Filter;
use alloy::sol_types::{SolEvent, SolValue};
use anyhow::Context;
use serde::Deserialize;

use crate::common::ethereum::{get_rate_limited_provider, AlloyProvider};
use crate::common::evm_selectors::facet_selectors_from_bytecode;
use crate::common::paths;
use crate::common::verification_report::VerificationResult;
use crate::deployment_verification::artifact_index::{ArtifactIndex, CodeMatch};
use crate::deployment_verification::chain_creation::{
    force_deployment_entries, verify_bytecode_info, BytecodeInfoVerdict,
};
use crate::deployment_verification::contracts::{
    IBridgehubView, IChainAssetHandlerView, IEcosystemEvents, IGovernanceView, IOwnableView,
    IRollupDAManagerView, IServerNotifierView, ITimelockView,
};
use crate::deployment_verification::discovery::{
    address_at_slot, probe, EIP1967_ADMIN_SLOT, EIP1967_IMPLEMENTATION_SLOT,
};
use crate::deployment_verification::roles::Role;

/// `L2_NATIVE_TOKEN_VAULT_ADDR`, the deployment-tracker leg of every NTV asset id.
const L2_NATIVE_TOKEN_VAULT_ADDR: Address =
    Address::new(alloy::hex!("0000000000000000000000000000000000010004"));
/// The facets `DeployCTMUtils.getChainCreationFacetCuts` puts in a chain
/// creation cut, in cut order. A cut that is not exactly this is not a chain
/// creation cut.
const CHAIN_CREATION_FACETS: [&str; 6] = [
    "AdminFacet",
    "GettersFacet",
    "MailboxFacet",
    "ExecutorFacet",
    "MigratorFacet",
    "CommitterFacet",
];
/// `L2_INTEROP_CENTER_ADDR` in `L2ContractAddresses.sol`.
const L2_INTEROP_CENTER_ADDR: Address =
    Address::new(alloy::hex!("000000000000000000000000000000000001000d"));
/// `PRIORITY_TX_MAX_GAS_LIMIT` in `Config.sol`.
const PRIORITY_TX_MAX_GAS_LIMIT: u64 = 72_000_000;
/// `MAINNET_CHAIN_ID` in `Config.sol`.
const MAINNET_CHAIN_ID: u64 = 1;
/// `MAINNET_COMMIT_TIMESTAMP_NOT_OLDER` / `TESTNET_COMMIT_TIMESTAMP_NOT_OLDER`.
const MAINNET_COMMIT_TIMESTAMP_NOT_OLDER: u64 = 3 * 24 * 60 * 60;
const TESTNET_COMMIT_TIMESTAMP_NOT_OLDER: u64 = 30 * 24 * 60 * 60;
/// `ETH_TOKEN_ADDRESS` in `Config.sol`.
const ETH_TOKEN_ADDRESS: Address =
    Address::new(alloy::hex!("0000000000000000000000000000000000000001"));

/// `DataEncoding.encodeNTVAssetId(l1ChainId, ETH_TOKEN_ADDRESS)`.
fn eth_token_asset_id(l1_chain_id: u64) -> FixedBytes<32> {
    keccak256(
        (
            U256::from(l1_chain_id),
            L2_NATIVE_TOKEN_VAULT_ADDR,
            ETH_TOKEN_ADDRESS,
        )
            .abi_encode(),
    )
}

/// Scheme id of `L2DACommitmentScheme.BLOBS_ZKSYNC_OS`.
const BLOBS_ZKSYNC_OS_SCHEME: u8 = 4;
/// Scheme id of `L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256`, i.e.
/// `ROLLUP_L2_DA_COMMITMENT_SCHEME`.
const ROLLUP_SCHEME: u8 = 3;

pub struct VerifyDeploymentInput {
    pub bridgehub: Address,
    pub l1_rpc_url: String,
    /// Lower bound for the log scans. The CTM deployment block is a good value.
    pub from_block: u64,
    pub expected_era_chain_id: Option<u64>,
    pub expected_weth: Option<Address>,
    pub expected_max_number_of_zk_chains: u64,
    pub expect_testnet_verifier: Option<bool>,
    /// L1 address of the token the ecosystem's `zkTokenAssetId` is meant to
    /// denote. Without it the asset id can only be reported, not checked.
    pub zk_token_l1_address: Option<Address>,
    /// Who should own `Governance` and `ChainAdminOwnable` — the root of the
    /// whole ecosystem. Everything else is derived from the deploy scripts.
    pub expected_ecosystem_owner: Option<Address>,
    /// Who should be `Governance.securityCouncil()`. It can `executeInstant`,
    /// so it is as privileged as the owner.
    pub expected_security_council: Option<Address>,
    /// Expected `Governance.minDelay()`.
    pub expected_min_delay: Option<U256>,
    pub genesis_config: Option<PathBuf>,
    /// Request pacing for hosted RPCs; see `get_rate_limited_provider`.
    pub compute_units_per_second: u64,
}

#[derive(Deserialize)]
struct GenesisConfig {
    genesis_root: FixedBytes<32>,
    protocol_semantic_version: SemanticVersion,
    #[serde(default)]
    prover: Option<ProverConfig>,
}

#[derive(Deserialize)]
struct SemanticVersion {
    major: u32,
    minor: u32,
    patch: u32,
}

#[derive(Deserialize)]
struct ProverConfig {
    recursion_scheduler_level_vk_hash: FixedBytes<32>,
}

/// Deployed runtime code, fetched at most once per address. The verifier
/// reads the same code for bytecode matching, immutable extraction and facet
/// selector reconstruction, and hosted RPCs rate-limit long before that
/// becomes free.
#[derive(Default)]
struct CodeCache(std::collections::HashMap<Address, alloy::primitives::Bytes>);

impl CodeCache {
    async fn get(
        &mut self,
        provider: &AlloyProvider,
        address: Address,
        block: u64,
    ) -> anyhow::Result<alloy::primitives::Bytes> {
        if let Some(code) = self.0.get(&address) {
            return Ok(code.clone());
        }
        let code = provider
            .get_code_at(address)
            .block_id(block.into())
            .await
            .with_context(|| format!("eth_getCode({address})"))?;
        self.0.insert(address, code.clone());
        Ok(code)
    }
}

/// One contract the verifier expects to find, and what it should be.
struct Expected {
    label: &'static str,
    address: Address,
    /// Artifact names that are acceptable. Empty means "whatever it is, just
    /// report it" — used for contracts whose flavour is a deployment choice.
    artifacts: Vec<&'static str>,
}

pub async fn run(input: VerifyDeploymentInput) -> anyhow::Result<()> {
    let provider = get_rate_limited_provider(&input.l1_rpc_url, input.compute_units_per_second)?;
    let mut code_cache = CodeCache::default();
    let input_ref = &input;
    let mut result = VerificationResult::labelled("verify-deployment");

    let chain_id = provider.get_chain_id().await.context("eth_chainId")?;
    // The latest block, captured once and used for every read. This is always
    // current state — never a historical block — but holding it fixed for the
    // run means a transaction landing mid-run cannot split the report across
    // two states.
    let to_block = provider
        .get_block_number()
        .await
        .context("eth_blockNumber")?;
    let index = load_artifacts(&mut result)?;

    result.print_section("Discovery");
    let core = discovery::discover_core(&provider, input.bridgehub, to_block).await?;
    result.expect(
        core.l1_chain_id == chain_id,
        &format!("Bridgehub L1_CHAIN_ID {} matches the RPC", core.l1_chain_id),
        &format!(
            "Bridgehub L1_CHAIN_ID is {} but the RPC reports chain {chain_id} — wrong network \
             or wrong bridgehub",
            core.l1_chain_id
        ),
    );

    // Before anything that replays events: an under-wide window makes CTM
    // discovery fail with a misleading "ecosystem not initialized", when the
    // real problem is the scan range.
    verify_scan_window_covers_deployment(&provider, &mut result, &core, input.from_block, to_block)
        .await?;

    let ctm_address = match crate::common::l1_contracts::discover_ctm_proxy_with(
        &provider,
        input.bridgehub,
        input.from_block,
        to_block,
    )
    .await
    {
        Ok(address) => address,
        Err(err) => {
            result.report_error(&format!(
                "no chain type manager could be discovered on this bridgehub: {err:#}"
            ));
            result.print_section("Summary");
            result.print_info(&format!(
                "{} error(s), {} warning(s) — stopped early: without a CTM there is nothing \
                 further to verify",
                result.errors, result.warnings
            ));
            return result.ensure_success();
        }
    };
    let ctm = discovery::discover_ctm(&provider, ctm_address, to_block).await?;
    // Discovery picks one CTM. Verifying an ecosystem that has more while
    // reporting success would be a false pass, so name the others and fail.
    let registered_ctms =
        registered_chain_type_managers(&provider, &core, input.from_block, to_block).await?;
    if registered_ctms.len() > 1 {
        result.report_error(&format!(
            "{} chain type managers are registered on this bridgehub ({}), but this command \
             verifies one ({}). Multi-CTM ecosystems are not supported; verify each CTM's \
             ecosystem separately.",
            registered_ctms.len(),
            registered_ctms
                .iter()
                .map(|address| format!("{address}"))
                .collect::<Vec<_>>()
                .join(", "),
            ctm.ctm
        ));
    }
    result.print_info(&format!(
        "  latest block {to_block}  bridgehub {}  ctm {}  protocol {}.{}.{} ({})",
        core.bridgehub, ctm.ctm, ctm.semver.0, ctm.semver.1, ctm.semver.2, ctm.protocol_version
    ));
    result.print_info(&format!(
        "  governance {}  chainAdmin {}  vm {}",
        core.governance,
        core.chain_admin,
        if ctm.is_zksync_os {
            "ZKsync OS"
        } else {
            "EraVM"
        }
    ));

    // An Era CTM is a finding, not a reason to stop: everything except the
    // force-deployment decoding still applies, and the caller gets a report.
    if !ctm.is_zksync_os {
        result.report_error(&format!(
            "the CTM at {} is an Era CTM. Its force deployments carry the Era bytecode-hash \
             encoding, which this command does not decode, so the chain creation section is \
             skipped. Era support is not implemented.",
            ctm.ctm
        ));
    }

    // Every conclusion drawn from logs below (chain creation params, pending
    // admins, the DA whitelist) is only as complete as the scan window. Anchor
    // it: the bridgehub proxy's own construction event must fall inside.
    // A missing or undecodable event is reported and the sections that depend
    // on it are skipped; the rest of the report still gets produced.
    let params = match ctm.is_zksync_os {
        true => match chain_creation::fetch(&provider, ctm.ctm, input.from_block, to_block).await {
            Ok(params) => Some(params),
            Err(err) => {
                result.report_error(&format!(
                    "chain creation parameters could not be read: {err:#}"
                ));
                None
            }
        },
        false => None,
    };
    // Without the chain creation params most sections have nothing to work
    // from. Return the report built so far rather than propagating an error,
    // so every finding already collected is still shown and the exit code
    // still reflects them.
    let Some(params) = params else {
        result.print_section("Summary");
        result.print_info(&format!(
            "{} error(s), {} warning(s) — stopped early: the chain creation parameters could \
             not be read, so the sections that depend on them were skipped",
            result.errors, result.warnings
        ));
        return result.ensure_success();
    };

    // ── bytecode ─────────────────────────────────────────────────────────
    result.print_section("Bytecode");
    let (expected, proxy_admins, zero_addresses) = build_expected_list(
        &provider,
        &mut code_cache,
        &core,
        &ctm,
        &params,
        &index,
        to_block,
    )
    .await?;
    for label in &zero_addresses {
        result.report_error(&format!(
            "{label} resolves to the zero address — the ecosystem is not fully wired, and any \
             check that compares it against another unset address would pass vacuously"
        ));
    }
    let mut exact = 0usize;
    let mut metadata_only = 0usize;
    for entry in &expected {
        let code = code_cache.get(&provider, entry.address, to_block).await?;
        if code.is_empty() {
            result.report_error(&format!("{} at {} has no code", entry.label, entry.address));
            continue;
        }
        let matches: Vec<_> = index.identify(&code);
        let accepted = matches.iter().find(|(artifact, _)| {
            entry.artifacts.is_empty() || entry.artifacts.contains(&artifact.name.as_str())
        });
        match accepted {
            Some((artifact, CodeMatch::Exact)) => {
                exact += 1;
                result.report_ok(&format!(
                    "{:<28} {} = {} (exact)",
                    entry.label, entry.address, artifact.name
                ));
            }
            Some((artifact, kind @ CodeMatch::MetadataOnly { .. })) => {
                metadata_only += 1;
                result.report_ok(&format!(
                    "{:<28} {} = {} ({})",
                    entry.label,
                    entry.address,
                    artifact.name,
                    kind.label()
                ));
            }
            None if matches.is_empty() => result.report_error(&format!(
                "{} at {} matches no contract in the local build (expected {:?}); the checkout \
                 is not the deployed commit, or this is not the contract it claims to be",
                entry.label, entry.address, entry.artifacts
            )),
            None => result.report_error(&format!(
                "{} at {} is {} — expected one of {:?}",
                entry.label,
                entry.address,
                matches
                    .iter()
                    .map(|(artifact, _)| artifact.name.as_str())
                    .collect::<Vec<_>>()
                    .join(" / "),
                entry.artifacts
            )),
        }
    }
    let matched = exact + metadata_only;
    result.print_info(&format!(
        "  {} contracts: {exact} exact, {metadata_only} metadata-only",
        expected.len()
    ));
    // A handful of mismatches is a real divergence worth chasing. A large
    // fraction almost never is: it means the local build is not the deployed
    // commit, or `forge build` was still running when the run started and
    // `out/` was a mix of old and new artifacts. Say so, because chasing it
    // as a deployment problem wastes the reader's time.
    let unmatched = expected.len() - matched;
    if unmatched > expected.len() / 4 {
        result.report_warn(&format!(
            "{unmatched} of {} contracts match nothing in the local build. That is far more \
             than a real divergence usually looks like — check that the checkout is the commit \
             the ecosystem was deployed from and that `forge build` finished before this run \
             (a partially written `out/` mixes artifacts from two commits). Compare a single \
             contract's length by hand before treating this as a deployment finding.",
            expected.len()
        ));
    }
    if metadata_only > 0 {
        result.report_warn(&format!(
            "{metadata_only} contract(s) match only after blanking CBOR metadata. Executable \
             code is identical, but the deployment is not bit-reproducible from this checkout — \
             which also means the genesis root and the L2 force-deployment hashes cannot be \
             independently reproduced. Build with `bytecode_hash = \"none\"` for deployments \
             that need to be verifiable by a third party."
        ));
    }

    // ── immutables ───────────────────────────────────────────────────────
    result.print_section("Immutables");
    let expectations = immutable_expectations(input_ref, &core, &ctm);
    for entry in &expected {
        let code = code_cache.get(&provider, entry.address, to_block).await?;
        // The *accepted* artifact, not merely the first that matches: a
        // same-code test double sorting earlier would otherwise supply the
        // name table and silently downgrade every check to a print.
        let Some((artifact, _)) = index.identify(&code).into_iter().find(|(artifact, _)| {
            entry.artifacts.is_empty() || entry.artifacts.contains(&artifact.name.as_str())
        }) else {
            continue;
        };
        let values = artifact.immutable_values(&code);
        if values.is_empty() {
            continue;
        }
        if !artifact.has_immutable_names() {
            result.report_warn(&format!(
                "{}: {} immutable(s) with no name table in artifact_index.rs — values printed \
                 positionally and not checked",
                entry.label,
                values.len()
            ));
        }
        for value in values {
            if value.inconsistent {
                result.report_error(&format!(
                    "{}.{} does not carry the same value at all {} of its use sites — masking \
                     hides this from the bytecode comparison, so the runtime executes with a \
                     value other than the one reported here",
                    entry.label, value.name, value.occurrences
                ));
                continue;
            }
            let actual = value.as_b256();
            match expectations.iter().find(|(name, _)| *name == value.name) {
                Some((_, want)) if *want == actual => result.report_ok(&format!(
                    "{:<28} {} = {}",
                    entry.label,
                    value.name,
                    render_immutable(&value)
                )),
                Some((_, want)) => result.report_error(&format!(
                    "{}.{} is {} — expected {want}",
                    entry.label,
                    value.name,
                    render_immutable(&value)
                )),
                None => result.print_info(&format!(
                    "  {:<28} {:<34} {}",
                    entry.label,
                    value.name,
                    render_immutable(&value)
                )),
            }
        }
    }

    // ── wiring ───────────────────────────────────────────────────────────
    result.print_section("Wiring");
    for (label, admin) in &proxy_admins {
        // ServerNotifier deliberately sits behind its own ChainAdmin-owned
        // ProxyAdmin; everything else shares the ecosystem one.
        let expected = if *label == "ServerNotifier" {
            ctm.server_notifier_proxy_admin
        } else {
            core.proxy_admin
        };
        result.expect(
            *admin == expected,
            &format!("{label} proxy admin is {expected}"),
            &format!(
                "{label} proxy admin is {admin}, expected {expected} — whoever holds this slot \
                 can replace the implementation"
            ),
        );
    }
    verify_wiring(&provider, &mut result, &core, &ctm, &index, to_block).await?;

    // ── chain creation ───────────────────────────────────────────────────
    result.print_section("Chain creation parameters");
    verify_chain_creation(
        &provider,
        &mut code_cache,
        &mut result,
        &input,
        &core,
        &ctm,
        &params,
        &index,
        to_block,
    )
    .await?;

    // ── verifier and genesis ─────────────────────────────────────────────
    result.print_section("Verifier and genesis");
    verify_verifier_and_genesis(&mut result, &input, &ctm, &params)?;

    // ── DA ───────────────────────────────────────────────────────────────
    result.print_section("Data availability");
    verify_da(
        &provider,
        &mut code_cache,
        &mut result,
        &input,
        &ctm,
        &index,
        &expected,
        to_block,
    )
    .await?;

    // ── privileged state ─────────────────────────────────────────────────
    result.print_section("Privileged state");
    verify_privileged_state(&provider, &mut result, &input, &core, &ctm, to_block).await?;

    // ── roles ────────────────────────────────────────────────────────────
    result.print_section("Roles");
    verify_roles(
        &provider,
        &mut result,
        &input,
        &core,
        &ctm,
        &expected,
        to_block,
    )
    .await?;

    // ── registered chains ────────────────────────────────────────────────
    result.print_section("Registered chains");
    let rollup_da_manager = expected
        .iter()
        .find(|entry| entry.label == "RollupDAManager")
        .map(|entry| entry.address);
    verify_chains(
        &provider,
        &mut result,
        &core,
        &ctm,
        rollup_da_manager,
        &params.diamond_cut.facetCuts,
        &index,
        &mut code_cache,
        to_block,
    )
    .await?;

    result.print_section("Summary");
    result.print_info(&format!(
        "{} error(s), {} warning(s)",
        result.errors, result.warnings
    ));
    result.ensure_success()
}

/// The role topology the deploy scripts establish.
///
/// `DeployL1CoreContracts.updateOwners` and `DeployCTM.updateOwners` decide
/// every one of these, so they are assertions rather than expectations the
/// operator has to supply. Only the root — who owns Governance and ChainAdmin
/// — is a deployment decision, and that comes in on flags.
fn expected_role_holders(
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    proxy_admins: &[(&'static str, Address)],
) -> Vec<(String, Role, Address)> {
    let governance_owned = [
        "L1Bridgehub",
        "ChainTypeManager",
        "L1AssetRouter",
        "L1Nullifier",
        "L1InteropHandler",
        "CTMDeploymentTracker",
        "L1ChainAssetHandler",
        "RollupDAManager",
        "ProxyAdmin",
        // Moved to Governance in #2459; before that they stayed with the
        // deployer, which is exactly the gap worth failing on.
        "L1NativeTokenVault",
        "ValidatorTimelock",
        "BridgedTokenBeacon",
        "ChainRegistrationSender",
    ];
    let mut out: Vec<(String, Role, Address)> = governance_owned
        .iter()
        .map(|label| (label.to_string(), Role::Owner, core.governance))
        .collect();

    out.push(("ServerNotifier".to_string(), Role::Owner, core.chain_admin));
    out.push((
        "ServerNotifier ProxyAdmin".to_string(),
        Role::Owner,
        core.chain_admin,
    ));
    out.push(("L1Bridgehub".to_string(), Role::Admin, core.chain_admin));
    out.push((
        "ChainTypeManager".to_string(),
        Role::Admin,
        core.chain_admin,
    ));

    // Both proxy admins are reached by label above; assert nothing extra here,
    // but keep the discovered set honest.
    debug_assert!(proxy_admins
        .iter()
        .any(|(label, _)| *label == "L1Bridgehub"));
    let _ = (ctm, proxy_admins);
    out
}

/// Every CTM currently registered on the bridgehub.
///
/// `ChainTypeManagerAdded` is append-only in the log, so registration is
/// re-checked on chain rather than inferred from the events alone.
async fn registered_chain_type_managers(
    provider: &AlloyProvider,
    core: &discovery::CoreAddresses,
    from_block: u64,
    to_block: u64,
) -> anyhow::Result<Vec<Address>> {
    let filter = Filter::new()
        .address(core.bridgehub)
        .event_signature(keccak256(b"ChainTypeManagerAdded(address)"))
        .from_block(from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for ChainTypeManagerAdded")?;

    let bridgehub = IBridgehubView::new(core.bridgehub, provider);
    let mut out: Vec<Address> = Vec::new();
    for log in logs {
        let Some(topic) = log.topics().get(1) else {
            continue;
        };
        let candidate = Address::from_slice(&topic[12..]);
        if out.contains(&candidate) {
            continue;
        }
        if bridgehub
            .chainTypeManagerIsRegistered(candidate)
            .block(to_block.into())
            .call()
            .await?
        {
            out.push(candidate);
        }
    }
    Ok(out)
}

/// Fails when `--from-block` starts after the ecosystem was deployed.
///
/// The pending-admin state, the DA whitelist, the settlement-layer whitelist
/// and the queued-operation scan are all reconstructed by replaying events,
/// and "no events found" is otherwise indistinguishable from "never set". A
/// window that misses the deployment turns a live pending handoff, an allowed
/// DA pair or a scheduled operation into a silent pass.
///
/// The anchor is that the bridgehub had no code in the block before the
/// window opens. An `Upgraded` log inside the range proves nothing, because an
/// implementation upgrade emits one too.
async fn verify_scan_window_covers_deployment(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    core: &discovery::CoreAddresses,
    from_block: u64,
    to_block: u64,
) -> anyhow::Result<()> {
    if from_block == 0 {
        result.report_ok("scan window starts at genesis and covers the whole chain");
        return Ok(());
    }
    let code = provider
        .get_code_at(core.bridgehub)
        .block_id((from_block - 1).into())
        .await
        .with_context(|| {
            format!(
                "eth_getCode({}) at block {}",
                core.bridgehub,
                from_block - 1
            )
        })?;
    result.expect(
        code.is_empty(),
        &format!("scan window {from_block}..={to_block} opens before the bridgehub existed"),
        &format!(
            "the bridgehub already had code at block {}, so --from-block {from_block} starts \
             after deployment. Everything replayed from events below — pending admins, the DA \
             and settlement-layer whitelists, queued governance operations — would report \
             'never set' for state that was set earlier. Lower --from-block.",
            from_block - 1
        ),
    );
    Ok(())
}

fn load_artifacts(result: &mut VerificationResult) -> anyhow::Result<ArtifactIndex> {
    let l1 = paths::resolve_l1_contracts_path()?;
    let da = paths::path_from_root("da-contracts");
    let index = ArtifactIndex::load(&[
        ("l1-contracts".to_string(), l1.join("out")),
        ("da-contracts".to_string(), da.join("out")),
    ])?;
    result.print_info(&format!(
        "Loaded {} artifacts from {} and {}",
        index.contract_count(),
        l1.join("out").display(),
        da.join("out").display()
    ));
    Ok(index)
}

/// Assembles the full contract inventory: proxies, the implementations behind
/// them, the diamond facets from the chain creation cut, and the singletons.
async fn build_expected_list(
    provider: &AlloyProvider,
    code_cache: &mut CodeCache,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    params: &chain_creation::ChainCreationParams,
    index: &ArtifactIndex,
    to_block: u64,
) -> anyhow::Result<(
    Vec<Expected>,
    Vec<(&'static str, Address)>,
    Vec<&'static str>,
)> {
    let mut out: Vec<Expected> = Vec::new();
    let mut proxy_admins: Vec<(&'static str, Address)> = Vec::new();
    let mut zero_addresses: Vec<&'static str> = Vec::new();
    macro_rules! add {
        ($label:expr, $address:expr, $artifacts:expr) => {
            out.push(Expected {
                label: $label,
                address: $address,
                artifacts: $artifacts,
            })
        };
    }

    add!("Governance", core.governance, vec!["Governance"]);
    add!(
        "ChainAdminOwnable",
        core.chain_admin,
        vec!["ChainAdminOwnable"]
    );
    add!("ProxyAdmin", core.proxy_admin, vec!["ProxyAdmin"]);
    add!(
        "ServerNotifier ProxyAdmin",
        ctm.server_notifier_proxy_admin,
        vec!["ProxyAdmin"]
    );
    add!(
        "BridgedTokenBeacon",
        core.bridged_token_beacon,
        vec!["UpgradeableBeacon"]
    );
    add!(
        "BridgedStandardERC20",
        core.bridged_standard_erc20,
        vec!["BridgedStandardERC20"]
    );

    let ctm_impl_names: Vec<&'static str> = if ctm.is_zksync_os {
        vec!["ZKsyncOSChainTypeManager"]
    } else {
        vec!["EraChainTypeManager"]
    };
    let verifier_names: Vec<&'static str> = match (ctm.is_zksync_os, ctm.verifier_is_testnet) {
        (true, false) => vec!["ZKsyncOSVerifier"],
        (true, true) => vec!["ZKsyncOSTestnetVerifier"],
        (false, false) => vec!["EraDualVerifier"],
        (false, true) => vec!["EraTestnetVerifier"],
    };
    let plonk_names: Vec<&'static str> = if ctm.is_zksync_os {
        vec!["ZKsyncOSVerifierPlonk"]
    } else {
        vec!["EraVerifierPlonk"]
    };
    let default_upgrade_names: Vec<&'static str> = if ctm.is_zksync_os {
        vec!["DefaultUpgradeZKsyncOS"]
    } else {
        vec!["DefaultUpgrade"]
    };

    // Proxies, each with the implementation behind it.
    let proxies: Vec<(&'static str, Address, Vec<&'static str>)> = vec![
        ("L1Bridgehub", core.bridgehub, vec!["L1Bridgehub"]),
        ("L1MessageRoot", core.message_root, vec!["L1MessageRoot"]),
        (
            "L1ChainAssetHandler",
            core.chain_asset_handler,
            vec!["L1ChainAssetHandler"],
        ),
        (
            "CTMDeploymentTracker",
            core.ctm_deployment_tracker,
            vec!["CTMDeploymentTracker"],
        ),
        (
            "ChainRegistrationSender",
            core.chain_registration_sender,
            vec!["ChainRegistrationSender"],
        ),
        ("L1AssetRouter", core.asset_router, vec!["L1AssetRouter"]),
        ("L1Nullifier", core.nullifier, vec!["L1Nullifier"]),
        (
            "L1NativeTokenVault",
            core.native_token_vault,
            vec!["L1NativeTokenVault"],
        ),
        (
            "L1InteropHandler",
            core.interop_handler,
            vec!["L1InteropHandler"],
        ),
        ("ChainTypeManager", ctm.ctm, ctm_impl_names),
        (
            "BytecodesSupplier",
            ctm.bytecodes_supplier,
            vec!["BytecodesSupplier"],
        ),
        (
            "PermissionlessValidator",
            ctm.permissionless_validator,
            vec!["PermissionlessValidator"],
        ),
        (
            "ServerNotifier",
            ctm.server_notifier,
            vec!["ServerNotifier"],
        ),
        // The timelock proxy is upgraded to MultisigCommitter after deploy, so
        // both implementations are legitimate.
        (
            "ValidatorTimelock",
            ctm.validator_timelock,
            vec!["MultisigCommitter", "ValidatorTimelock"],
        ),
    ];
    for (label, address, impl_names) in proxies {
        if address == Address::ZERO {
            // Skipping this used to hide an unwired ecosystem: the Nullifier
            // wiring check then compares zero against zero and passes.
            zero_addresses.push(label);
            continue;
        }
        add!(label, address, vec!["TransparentUpgradeableProxy"]);
        // Whoever holds the admin slot can replace the implementation, so a
        // proxy running the right code under an unexpected admin is not a
        // verified proxy.
        proxy_admins.push((
            label,
            address_at_slot(provider, address, EIP1967_ADMIN_SLOT, to_block).await?,
        ));
        let implementation =
            address_at_slot(provider, address, EIP1967_IMPLEMENTATION_SLOT, to_block).await?;
        out.push(Expected {
            label: Box::leak(format!("{label} impl").into_boxed_str()),
            address: implementation,
            artifacts: impl_names,
        });
    }

    add!("Verifier", ctm.verifier, verifier_names);
    add!("VerifierPlonk", ctm.plonk_verifier, plonk_names);
    add!(
        "L1GenesisUpgrade",
        ctm.genesis_upgrade,
        vec!["L1GenesisUpgrade"]
    );
    add!("DefaultUpgrade", ctm.default_upgrade, default_upgrade_names);

    // Diamond facets come from the live chain creation cut, in cut order.
    for (position, cut) in params.diamond_cut.facetCuts.iter().enumerate() {
        let label: &'static str = CHAIN_CREATION_FACETS
            .get(position)
            .copied()
            .unwrap_or("Facet (unexpected position)");
        add!(label, cut.facet, vec![label]);
    }
    add!(
        "DiamondInit",
        params.diamond_cut.initAddress,
        vec!["DiamondInit"]
    );

    // The rollup DA manager and the 7702 checker are only reachable through
    // facet immutables, so they are discovered rather than configured.
    if let Some(address) = immutable_address(
        index,
        provider,
        code_cache,
        params,
        0,
        "ROLLUP_DA_MANAGER",
        to_block,
    )
    .await?
    {
        add!("RollupDAManager", address, vec!["RollupDAManager"]);
    }
    if let Some(address) = immutable_address(
        index,
        provider,
        code_cache,
        params,
        2,
        "EIP_7702_CHECKER",
        to_block,
    )
    .await?
    {
        add!("EIP7702Checker", address, vec!["EIP7702Checker"]);
    }

    Ok((out, proxy_admins, zero_addresses))
}

/// Reads one named immutable out of a deployed facet.
async fn immutable_address(
    index: &ArtifactIndex,
    provider: &AlloyProvider,
    code_cache: &mut CodeCache,
    params: &chain_creation::ChainCreationParams,
    facet_position: usize,
    immutable: &str,
    to_block: u64,
) -> anyhow::Result<Option<Address>> {
    let Some(cut) = params.diamond_cut.facetCuts.get(facet_position) else {
        return Ok(None);
    };
    let code = code_cache.get(provider, cut.facet, to_block).await?;
    let Some((artifact, _)) = index.identify(&code).into_iter().next() else {
        return Ok(None);
    };
    Ok(artifact
        .immutable_values(&code)
        .into_iter()
        .find(|value| value.name == immutable)
        .and_then(|value| value.as_address()))
}

async fn verify_wiring(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    _index: &ArtifactIndex,
    to_block: u64,
) -> anyhow::Result<()> {
    let wiring = discovery::read_bridge_wiring(provider, core, to_block).await?;
    let mut check = |ok: bool, what: &str, detail: String| {
        if ok {
            result.report_ok(what);
        } else {
            result.report_error(&format!("{what} — {detail}"));
        }
    };

    check(
        wiring.nullifier_asset_router == core.asset_router,
        "L1Nullifier.l1AssetRouter",
        format!("got {}", wiring.nullifier_asset_router),
    );
    check(
        wiring.nullifier_native_token_vault == core.native_token_vault,
        "L1Nullifier.l1NativeTokenVault",
        format!("got {}", wiring.nullifier_native_token_vault),
    );
    check(
        wiring.nullifier_interop_handler == core.interop_handler,
        "L1Nullifier.l1InteropHandler",
        format!("got {}", wiring.nullifier_interop_handler),
    );
    check(
        wiring.ntv_weth == core.l1_weth,
        "L1NativeTokenVault.WETH_TOKEN agrees with L1AssetRouter",
        format!("{} vs {}", wiring.ntv_weth, core.l1_weth),
    );

    let cah = IChainAssetHandlerView::new(core.chain_asset_handler, provider);
    let cah_message_root = cah.MESSAGE_ROOT().block(to_block.into()).call().await?;
    let cah_asset_router = cah.ASSET_ROUTER().block(to_block.into()).call().await?;
    check(
        cah_message_root == core.message_root && cah_asset_router == core.asset_router,
        "L1ChainAssetHandler.setAddresses was run",
        format!("messageRoot {cah_message_root}, assetRouter {cah_asset_router}"),
    );

    let notifier_ctm = IServerNotifierView::new(ctm.server_notifier, provider)
        .chainTypeManager()
        .block(to_block.into())
        .call()
        .await?;
    check(
        notifier_ctm == ctm.ctm,
        "ServerNotifier.setChainTypeManager was run",
        format!("got {notifier_ctm}"),
    );
    check(
        ctm.default_upgrade != Address::ZERO,
        "ChainTypeManager.setDefaultUpgrade was run",
        "defaultUpgrade is zero — verifier-only and patch upgrades will revert".to_string(),
    );

    // CTM registration on the bridgehub: three separate calls, all required
    // before `createNewChain` works.
    let bh = IBridgehubView::new(core.bridgehub, provider);
    let registered = bh
        .chainTypeManagerIsRegistered(ctm.ctm)
        .block(to_block.into())
        .call()
        .await?;
    check(
        registered,
        "Bridgehub.addChainTypeManager was run",
        "CTM is not registered; createNewChain reverts CTMNotRegistered".to_string(),
    );

    let asset_id = bh
        .ctmAssetIdFromAddress(ctm.ctm)
        .block(to_block.into())
        .call()
        .await?;
    let expected_asset_id = keccak256(
        (
            U256::from(core.l1_chain_id),
            core.ctm_deployment_tracker,
            FixedBytes::<32>::left_padding_from(ctm.ctm.as_slice()),
        )
            .abi_encode(),
    );
    check(
        asset_id == expected_asset_id,
        "CTM asset id derives from (l1ChainId, ctmDeploymentTracker, ctm)",
        format!("got {asset_id}, expected {expected_asset_id}"),
    );
    let back = bh
        .ctmAssetIdToAddress(asset_id)
        .block(to_block.into())
        .call()
        .await?;
    check(
        back == ctm.ctm,
        "Bridgehub CTM asset id round-trips",
        format!("got {back}"),
    );

    let ar = contracts::IAssetRouterView::new(core.asset_router, provider);
    let ctm_handler = ar
        .assetHandlerAddress(asset_id)
        .block(to_block.into())
        .call()
        .await?;
    check(
        ctm_handler == core.chain_asset_handler,
        "AssetRouter routes the CTM asset to the ChainAssetHandler",
        format!("got {ctm_handler}"),
    );
    let eth_handler = ar
        .assetHandlerAddress(core.eth_token_asset_id)
        .block(to_block.into())
        .call()
        .await?;
    check(
        eth_handler == core.native_token_vault,
        "AssetRouter routes ETH to the NativeTokenVault (registerEthToken was run)",
        format!("got {eth_handler}"),
    );

    let l1_whitelisted = bh
        .whitelistedSettlementLayers(U256::from(core.l1_chain_id))
        .block(to_block.into())
        .call()
        .await?;
    check(
        l1_whitelisted,
        "L1 is a whitelisted settlement layer",
        "chains cannot settle on L1".to_string(),
    );

    // `setBridgehubParams` registers `baseTokenAssetId(eraChainId)`. On a fresh
    // ecosystem that chain does not exist, so it registers the zero asset id —
    // inert (chain creation rejects a zero asset id) but not what was meant.
    if bh
        .assetIdIsRegistered(FixedBytes::ZERO)
        .block(to_block.into())
        .call()
        .await?
    {
        result.report_warn(
            "assetIdIsRegistered[bytes32(0)] is true: `addTokenAssetId(baseTokenAssetId(eraChainId))` \
             ran against a chain that does not exist on this ecosystem, registering the zero asset \
             id. Inert, but the call did not do what it was meant to.",
        );
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn verify_chain_creation(
    provider: &AlloyProvider,
    code_cache: &mut CodeCache,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    params: &chain_creation::ChainCreationParams,
    index: &ArtifactIndex,
    to_block: u64,
) -> anyhow::Result<()> {
    result.print_info(&format!(
        "  parameters last set at block {} ({} of {} NewChainCreationParams event(s) — the \
         newest is the one in force)",
        params.block_number, params.revision, params.revisions
    ));
    if params.revisions > 1 {
        result.report_warn(&format!(
            "chain creation parameters have been set {} times; the deployment-time values were \
             superseded at block {}. Chains created before that carry the older parameters.",
            params.revisions, params.block_number
        ));
    }

    // Bind the decoded event to the hashes the CTM actually stores. Until
    // these three match, nothing else in this section means anything.
    let bound = [
        (
            "storedBatchZero",
            params.recompute_stored_batch_zero(),
            ctm.stored_batch_zero,
        ),
        (
            "initialCutHash",
            params.recompute_initial_cut_hash(),
            ctm.initial_cut_hash,
        ),
        (
            "initialForceDeploymentHash",
            params.recompute_force_deployment_hash(),
            ctm.initial_force_deployment_hash,
        ),
    ];
    let mut all_bound = true;
    for (name, recomputed, stored) in bound {
        let ok = recomputed == stored;
        all_bound &= ok;
        result.expect(
            ok,
            &format!("{name} recomputes from NewChainCreationParams"),
            &format!("{name}: recomputed {recomputed}, CTM stores {stored}"),
        );
    }
    if !all_bound {
        result.report_error(
            "the decoded chain creation params do not hash to the CTM's stored values; \
             everything below is derived from them and cannot be trusted",
        );
        return Ok(());
    }

    result.expect(
        params.genesis_upgrade == ctm.genesis_upgrade,
        "genesisUpgrade in the cut matches ctm.l1GenesisUpgrade()",
        &format!(
            "cut has {}, ctm has {}",
            params.genesis_upgrade, ctm.genesis_upgrade
        ),
    );

    if ctm.is_zksync_os {
        result.expect(
            params.genesis_batch_commitment == FixedBytes::left_padding_from(&[1]),
            "genesisBatchCommitment is 1 (fixed for ZKsync OS)",
            &format!("got {}", params.genesis_batch_commitment),
        );
        result.expect(
            params.genesis_index_repeated_storage_changes == 0,
            "genesisIndexRepeatedStorageChanges is 0",
            &format!("got {}", params.genesis_index_repeated_storage_changes),
        );
        // `DiamondInit.initialize` decodes three bytes32 that ZKsync OS does
        // not use. Checking only that the supplied bytes are zero passes
        // vacuously on empty or truncated calldata, which would still make
        // chain creation revert — so the length is part of the check.
        const DIAMOND_INIT_CALLDATA_LEN: usize = 3 * 32;
        let init = &params.diamond_cut.initCalldata;
        result.expect(
            init.len() == DIAMOND_INIT_CALLDATA_LEN && init.iter().all(|byte| *byte == 0),
            "diamondCut.initCalldata is three zero words (no EraVM bytecode hashes)",
            &format!(
                "diamondCut.initCalldata is {} bytes (0x{}), expected \
                 {DIAMOND_INIT_CALLDATA_LEN} zero bytes",
                init.len(),
                alloy::hex::encode(init)
            ),
        );
    }

    // ── the diamond cut ──────────────────────────────────────────────────
    // The cut is governance-supplied data: iterating whatever it contains
    // would let a short cut (no CommitterFacet, say) pass every per-facet
    // check and still produce chains that cannot commit.
    let expected_freezable = [false, false, true, true, false, true];
    result.expect(
        params.diamond_cut.facetCuts.len() == CHAIN_CREATION_FACETS.len(),
        &format!(
            "chain creation cut has all {} canonical facets",
            CHAIN_CREATION_FACETS.len()
        ),
        &format!(
            "chain creation cut has {} facets, expected the canonical {:?}",
            params.diamond_cut.facetCuts.len(),
            CHAIN_CREATION_FACETS
        ),
    );
    let mut seen: HashSet<[u8; 4]> = HashSet::new();
    let mut duplicates = 0usize;
    for (position, cut) in params.diamond_cut.facetCuts.iter().enumerate() {
        let code = code_cache.get(provider, cut.facet, to_block).await?;
        let from_bytecode = facet_selectors_from_bytecode(&code);
        let in_cut = chain_creation::cut_selectors(&cut.selectors);

        result.expect(
            cut.action == 0,
            &format!("facet {position} action is Add"),
            &format!("facet {position} action is {}", cut.action),
        );
        if let Some(expected) = expected_freezable.get(position) {
            result.expect(
                cut.isFreezable == *expected,
                &format!("facet {position} isFreezable = {expected}"),
                &format!(
                    "facet {position} isFreezable = {} (expected {expected})",
                    cut.isFreezable
                ),
            );
        }
        result.expect(
            in_cut == from_bytecode,
            &format!(
                "facet {position} at {} lists all {} dispatcher selectors",
                cut.facet,
                from_bytecode.len()
            ),
            &format!(
                "facet {position} at {}: cut has {} selectors, bytecode dispatches {} \
                 (missing {:?})",
                cut.facet,
                in_cut.len(),
                from_bytecode.len(),
                from_bytecode
                    .difference(&in_cut)
                    .map(|selector| format!("0x{}", alloy::hex::encode(selector)))
                    .collect::<Vec<_>>()
            ),
        );
        // Independent cross-check: the artifact ABI should agree with what
        // `evmole` reads out of the bytecode.
        if let Some((artifact, _)) = index.identify(&code).into_iter().next() {
            if artifact.abi_selectors != from_bytecode {
                result.report_warn(&format!(
                    "facet {position} ({}): ABI lists {} selectors, bytecode dispatches {}",
                    artifact.name,
                    artifact.abi_selectors.len(),
                    from_bytecode.len()
                ));
            }
        }
        for selector in in_cut {
            if !seen.insert(selector) {
                duplicates += 1;
            }
        }
    }
    result.expect(
        duplicates == 0,
        &format!(
            "diamond cut has {} unique selectors, no collisions",
            seen.len()
        ),
        &format!("diamond cut has {duplicates} duplicated selector(s)"),
    );

    // ── the force deployments blob ───────────────────────────────────────
    let data = &params.force_deployments;
    result.expect(
        data.l1ChainId == U256::from(core.l1_chain_id),
        "forceDeployments.l1ChainId",
        &format!("got {}", data.l1ChainId),
    );
    // Always reconcile against the value already baked into L1AssetRouter:
    // the two drive L1 and future-L2 routing and must agree whether or not the
    // operator supplied an external expectation.
    result.expect(
        data.eraChainId == core.era_chain_id,
        "forceDeployments.eraChainId agrees with L1AssetRouter.ERA_CHAIN_ID",
        &format!(
            "forceDeployments.eraChainId is {} but L1AssetRouter.ERA_CHAIN_ID is {}",
            data.eraChainId, core.era_chain_id
        ),
    );
    if let Some(era_chain_id) = input.expected_era_chain_id {
        result.expect(
            data.eraChainId == U256::from(era_chain_id),
            &format!("forceDeployments.eraChainId is {era_chain_id}"),
            &format!("got {}, expected {era_chain_id}", data.eraChainId),
        );
    }
    result.expect(
        data.l1AssetRouter == core.asset_router,
        "forceDeployments.l1AssetRouter",
        &format!("got {}", data.l1AssetRouter),
    );
    result.expect(
        data.aliasedL1Governance == apply_l1_to_l2_alias(core.governance),
        "forceDeployments.aliasedL1Governance is the aliased Governance",
        &format!(
            "got {}, expected {}",
            data.aliasedL1Governance,
            apply_l1_to_l2_alias(core.governance)
        ),
    );
    result.expect(
        data.aliasedChainRegistrationSender == apply_l1_to_l2_alias(core.chain_registration_sender),
        "forceDeployments.aliasedChainRegistrationSender",
        &format!("got {}", data.aliasedChainRegistrationSender),
    );
    result.expect(
        data.dangerousTestOnlyForcedBeacon == Address::ZERO,
        "forceDeployments.dangerousTestOnlyForcedBeacon is zero",
        &format!(
            "got {} — this must be zero outside tests",
            data.dangerousTestOnlyForcedBeacon
        ),
    );
    result.expect(
        data.maxNumberOfZKChains == U256::from(input.expected_max_number_of_zk_chains),
        &format!(
            "forceDeployments.maxNumberOfZKChains is {}",
            input.expected_max_number_of_zk_chains
        ),
        &format!(
            "forceDeployments.maxNumberOfZKChains is {} but the L1 Bridgehub allows {}. Every \
             chain created here gets that value as its L2 MAX_NUMBER_OF_ZK_CHAINS, and it is \
             baked into initialForceDeploymentHash — changing it needs setChainCreationParams. \
             Root cause is usually DeployCTMConfig not carrying `max_number_of_chains`.",
            data.maxNumberOfZKChains, core.max_number_of_zk_chains
        ),
    );

    verify_zk_token_asset_id(provider, result, input, core, data.zkTokenAssetId, to_block).await?;

    // L2 implementations, and the SystemContractProxy each one is installed
    // behind, that every new chain force-deploys. These contracts never land
    // on L1, so the reference is the repo's committed hash record rather than a
    // local build — and against a fixed record the match must be exact.
    let record = chain_creation::L2BytecodeRecord::load()?;
    let mut report_verdict = |what: String, verdict: BytecodeInfoVerdict| match verdict {
        BytecodeInfoVerdict::Exact => result.report_ok(&what),
        BytecodeInfoVerdict::Mismatch { expected } => result.report_error(&format!(
            "{what}: AllContractsHashes.json records blake {} / {} bytes / keccak {}",
            expected.blake, expected.length, expected.keccak
        )),
        BytecodeInfoVerdict::MissingRecord => result.report_error(&format!(
            "{what}: no entry in AllContractsHashes.json — run `yarn calculate-hashes:fix`"
        )),
    };

    for entry in force_deployment_entries(data)? {
        report_verdict(
            format!("forceDeployments.{} = {}", entry.field, entry.contract),
            verify_bytecode_info(&record, entry.contract, &entry.implementation),
        );
        // The proxy half is force-deployed at the fixed L2 address itself, so
        // a wrong one takes over every core contract.
        report_verdict(
            format!("forceDeployments.{} proxy", entry.field),
            verify_bytecode_info(
                &record,
                chain_creation::SYSTEM_CONTRACT_PROXY_CONTRACT,
                &entry.proxy,
            ),
        );
    }

    // `l2TokenProxyBytecodeHash` is the keccak of the deployed BeaconProxy code
    // and is written into the L2 native token vault at genesis; a wrong value
    // breaks every bridged token the chain ever deploys.
    match record.get(chain_creation::BEACON_PROXY_CONTRACT) {
        Some(beacon_proxy) => {
            result.expect(
                data.l2TokenProxyBytecodeHash == beacon_proxy.keccak,
                "forceDeployments.l2TokenProxyBytecodeHash = BeaconProxy",
                &format!(
                    "forceDeployments.l2TokenProxyBytecodeHash is {} but \
                     AllContractsHashes.json records BeaconProxy as {}",
                    data.l2TokenProxyBytecodeHash, beacon_proxy.keccak
                ),
            );
        }
        None => result.report_error(
            "no BeaconProxy entry in AllContractsHashes.json; cannot check \
             forceDeployments.l2TokenProxyBytecodeHash",
        ),
    };

    Ok(())
}

/// The ZK token asset id is `keccak(abi.encode(originChainId, L2_NTV, token))`.
/// Reusing another ecosystem's value silently points every chain at an asset
/// nothing here can bridge, and `InteropCenter` writes it once at genesis with
/// no setter — so it is unfixable on a chain that already exists.
async fn verify_zk_token_asset_id(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    on_chain: FixedBytes<32>,
    to_block: u64,
) -> anyhow::Result<()> {
    result.expect(
        on_chain != FixedBytes::ZERO,
        "forceDeployments.zkTokenAssetId is set",
        "forceDeployments.zkTokenAssetId is zero; InteropCenter.initL2 reverts ZKTokenNotAvailable",
    );

    match input.zk_token_l1_address {
        Some(token) => {
            let expected = keccak256(
                (
                    U256::from(core.l1_chain_id),
                    L2_NATIVE_TOKEN_VAULT_ADDR,
                    token,
                )
                    .abi_encode(),
            );
            result.expect(
                on_chain == expected,
                &format!("zkTokenAssetId derives from this ecosystem's L1 token {token}"),
                &format!(
                    "zkTokenAssetId is {on_chain} but keccak(abi.encode({}, L2_NTV, {token})) is \
                     {expected}. The deployed value denotes a token native to a different chain, \
                     so L1NativeTokenVault can never resolve it and every fixed-fee interop call \
                     reverts ZKTokenNotAvailable. InteropCenter sets ZK_TOKEN_ASSET_ID only in \
                     initL2 (which disables initializers) — chains already created with it \
                     cannot be fixed in place.",
                    core.l1_chain_id
                ),
            );
        }
        None => {
            let registered =
                contracts::INativeTokenVaultView::new(core.native_token_vault, provider)
                    .tokenAddress(on_chain)
                    .block(to_block.into())
                    .call()
                    .await?;
            result.report_warn(&format!(
                "zkTokenAssetId {on_chain} could not be bound to an L1 token — pass \
                 --zk-token-l1-address to check it. L1NativeTokenVault.tokenAddress() currently \
                 resolves it to {registered}; a zero here on an ecosystem whose ZK token has \
                 already been bridged means the asset id belongs to another ecosystem."
            ));
        }
    }
    Ok(())
}

fn verify_verifier_and_genesis(
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    ctm: &discovery::CtmAddresses,
    params: &chain_creation::ChainCreationParams,
) -> anyhow::Result<()> {
    result.print_info(&format!(
        "  verifier {} (plonk {}), vk {}",
        ctm.verifier, ctm.plonk_verifier, ctm.verification_key_hash
    ));
    if let Some(expected) = input.expect_testnet_verifier {
        result.expect(
            ctm.verifier_is_testnet == expected,
            &format!(
                "verifier is the {} one",
                if expected { "testnet" } else { "production" }
            ),
            &format!(
                "verifier is the {} one but --expect-testnet-verifier is {expected}. A \
                 production verifier on a testnet ecosystem means no mock proofs: every batch \
                 needs a real proof from a matching prover.",
                if ctm.verifier_is_testnet {
                    "testnet"
                } else {
                    "production"
                }
            ),
        );
    } else if !ctm.verifier_is_testnet {
        result.report_warn(
            "the production verifier is deployed. Confirm this is intended for this environment \
             — a testnet ecosystem normally runs the testnet verifier so chains can commit and \
             prove with mock proofs.",
        );
    }

    let genesis_path = input
        .genesis_config
        .clone()
        .unwrap_or_else(|| paths::path_from_root("configs/genesis/zksync-os/latest.json"));
    let contents = std::fs::read_to_string(&genesis_path)
        .with_context(|| format!("reading {}", genesis_path.display()))?;
    let genesis: GenesisConfig = serde_json::from_str(&contents)
        .with_context(|| format!("parsing {}", genesis_path.display()))?;

    result.expect(
        (
            genesis.protocol_semantic_version.major,
            genesis.protocol_semantic_version.minor,
            genesis.protocol_semantic_version.patch,
        ) == ctm.semver,
        &format!(
            "genesis config semver {}.{}.{} matches the CTM",
            ctm.semver.0, ctm.semver.1, ctm.semver.2
        ),
        &format!(
            "genesis config is {}.{}.{} but the CTM reports {}.{}.{}",
            genesis.protocol_semantic_version.major,
            genesis.protocol_semantic_version.minor,
            genesis.protocol_semantic_version.patch,
            ctm.semver.0,
            ctm.semver.1,
            ctm.semver.2
        ),
    );
    result.expect(
        genesis.genesis_root == params.genesis_batch_hash,
        "deployed genesis root matches the committed genesis config",
        &format!(
            "the CTM was initialised with genesis root {} but {} carries {}. A chain created \
             from a build of this checkout would be bricked at its genesis upgrade transaction \
             and burn its chain id. Regenerate the genesis config and commit it.",
            params.genesis_batch_hash,
            genesis_path.display(),
            genesis.genesis_root
        ),
    );
    if let Some(prover) = genesis.prover {
        result.expect(
            prover.recursion_scheduler_level_vk_hash == ctm.verification_key_hash,
            "prover VK hash in the genesis config matches the deployed verifier",
            &format!(
                "the deployed verifier reports VK {} but the genesis config carries {}. Nothing \
                 on L1 checks this, so it surfaces as `finalPairing: pairing failure` on the \
                 first prove. Resolve against the prover repo, which is the source of truth.",
                ctm.verification_key_hash, prover.recursion_scheduler_level_vk_hash
            ),
        );
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn verify_da(
    provider: &AlloyProvider,
    code_cache: &mut CodeCache,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    ctm: &discovery::CtmAddresses,
    index: &ArtifactIndex,
    expected: &[Expected],
    to_block: u64,
) -> anyhow::Result<()> {
    let Some(manager) = expected
        .iter()
        .find(|entry| entry.label == "RollupDAManager")
        .map(|entry| entry.address)
    else {
        result.report_warn("RollupDAManager not discovered; skipping DA checks");
        return Ok(());
    };

    let filter = Filter::new()
        .address(manager)
        .event_signature(IEcosystemEvents::DAPairUpdated::SIGNATURE_HASH)
        .from_block(input.from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for DAPairUpdated")?;

    let mut allowed: Vec<(Address, u8)> = Vec::new();
    for log in &logs {
        let event = IEcosystemEvents::DAPairUpdated::decode_log_data(log.data())?;
        let pair = (event.l1DAValidator, event.l2Scheme);
        allowed.retain(|existing| *existing != pair);
        if event.status {
            allowed.push(pair);
        }
    }
    // A whitelisted address is only meaningful if it is actually one of the DA
    // validators: nothing stops an EOA or an arbitrary contract being paired.
    const DA_VALIDATOR_ARTIFACTS: [&str; 4] = [
        "RollupL1DAValidator",
        "BlobsL1DAValidatorZKsyncOS",
        "ValidiumL1DAValidator",
        "AvailL1DAValidator",
    ];
    for (validator, scheme) in &allowed {
        let code = code_cache.get(provider, *validator, to_block).await?;
        let identified = index
            .identify(&code)
            .into_iter()
            .find(|(artifact, _)| DA_VALIDATOR_ARTIFACTS.contains(&artifact.name.as_str()));
        match identified {
            Some((artifact, kind)) => result.report_ok(&format!(
                "allowed DA pair: {validator} scheme {scheme} = {} ({})",
                artifact.name,
                kind.label()
            )),
            None if code.is_empty() => result.report_error(&format!(
                "allowed DA pair: {validator} scheme {scheme} has no code — chains pairing with \
                 it cannot post DA"
            )),
            None => result.report_error(&format!(
                "allowed DA pair: {validator} scheme {scheme} is not any of {DA_VALIDATOR_ARTIFACTS:?} \
                 in the local build"
            )),
        }
    }
    result.expect(
        !allowed.is_empty(),
        "RollupDAManager has at least one allowed DA pair",
        "no DA pair is whitelisted; rollup chains cannot become permanent rollups",
    );

    if ctm.is_zksync_os {
        // A ZKsync OS chain's natural pair is its blobs validator at
        // `BLOBS_ZKSYNC_OS`. `Admin.makePermanentRollup` re-checks the pair,
        // so a chain running scheme 4 with only scheme 3 whitelisted can
        // never lock itself in.
        let has_zkos_scheme = allowed
            .iter()
            .any(|(_, scheme)| *scheme == BLOBS_ZKSYNC_OS_SCHEME);
        let manager_view = IRollupDAManagerView::new(manager, provider);
        let rollup_only: Vec<_> = allowed
            .iter()
            .filter(|(_, scheme)| *scheme == ROLLUP_SCHEME)
            .collect();
        if !has_zkos_scheme && !rollup_only.is_empty() {
            result.report_warn(&format!(
                "no DA pair is whitelisted at scheme {BLOBS_ZKSYNC_OS_SCHEME} (BLOBS_ZKSYNC_OS); \
                 only scheme {ROLLUP_SCHEME} is. A ZKsync OS chain running its natural DA pair \
                 reverts InvalidDAForPermanentRollup in makePermanentRollup(). Root cause is \
                 usually DeployCTMUtils.getRollupL2DACommitmentScheme() ignoring isZKsyncOS."
            ));
            // Confirm against the live getter rather than only the log replay.
            for (validator, _) in &rollup_only {
                let live = manager_view
                    .isPairAllowed(*validator, BLOBS_ZKSYNC_OS_SCHEME)
                    .block(to_block.into())
                    .call()
                    .await?;
                if live {
                    result.report_warn(&format!(
                        "…but {validator} is allowed at scheme {BLOBS_ZKSYNC_OS_SCHEME} on chain; \
                         the log replay above is incomplete, widen --from-block"
                    ));
                }
            }
        }
    }
    Ok(())
}

/// State that is not code and not wiring, but decides who can do what next:
/// queued governance operations, staged upgrade cuts, the settlement-layer
/// whitelist, pause flags, and the validator sets.
///
/// Every finding here is reported and the sweep continues — a pending
/// operation is a reason to fail the run, not a reason to stop looking.
async fn verify_privileged_state(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    to_block: u64,
) -> anyhow::Result<()> {
    // ── queued governance operations ──
    // Both schedule events are collected. A shadow operation publishes only
    // its id by design, so the contents cannot be recovered — but its being
    // pending is exactly what matters, and that is readable.
    let mut pending = Vec::new();
    for (signature, shadow) in [
        (
            IEcosystemEvents::TransparentOperationScheduled::SIGNATURE_HASH,
            false,
        ),
        (
            IEcosystemEvents::ShadowOperationScheduled::SIGNATURE_HASH,
            true,
        ),
    ] {
        let filter = Filter::new()
            .address(core.governance)
            .event_signature(signature)
            .from_block(input.from_block)
            .to_block(to_block);
        let logs = provider
            .get_logs(&filter)
            .await
            .context("eth_getLogs for scheduled governance operations")?;
        let governance = IGovernanceView::new(core.governance, provider);
        for log in logs {
            let Some(id) = log.topics().get(1).copied() else {
                continue;
            };
            if governance
                .isOperationPending(id)
                .block(to_block.into())
                .call()
                .await?
            {
                pending.push((id, shadow));
            }
        }
    }
    if pending.is_empty() {
        result.report_ok("no governance operation is pending");
    }
    for (id, shadow) in &pending {
        result.report_error(&format!(
            "governance operation {id} is scheduled and still pending{}. Whoever owns \
             Governance can execute it at will; on this ecosystem that means it is queued \
             against contracts this report otherwise passes.",
            if *shadow {
                " (a shadow operation — its calls are not published on chain and cannot be \
                 recovered from L1 until it executes)"
            } else {
                ""
            }
        ));
    }

    // ── staged upgrade cuts on the CTM ──
    let filter = Filter::new()
        .address(ctm.ctm)
        .event_signature(IEcosystemEvents::NewUpgradeCutHash::SIGNATURE_HASH)
        .from_block(input.from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for NewUpgradeCutHash")?;
    let ctm_view = contracts::ICtmView::new(ctm.ctm, provider);
    let mut staged = 0usize;
    for log in &logs {
        let Some(version) = log.topics().get(1) else {
            continue;
        };
        let version = U256::from_be_bytes(version.0);
        let cut_hash = ctm_view
            .upgradeCutHash(version)
            .block(to_block.into())
            .call()
            .await?;
        if cut_hash != FixedBytes::ZERO {
            staged += 1;
            result.report_error(&format!(
                "an upgrade cut is registered for protocol version {version} (cut hash \
                 {cut_hash}). A chain admin can apply it with `upgradeChainFromVersion`; on a \
                 freshly deployed ecosystem nothing should be staged."
            ));
        }
    }
    if staged == 0 {
        result.report_ok("no upgrade cut is staged on the CTM");
    }
    let deadline = ctm_view
        .protocolVersionDeadline(ctm.protocol_version)
        .block(to_block.into())
        .call()
        .await?;
    result.expect(
        deadline == U256::MAX,
        "the current protocol version has no upgrade deadline",
        &format!(
            "protocolVersionDeadline for the current version is {deadline}, not unlimited: \
             chain creation stops working once it passes"
        ),
    );

    // ── settlement layer whitelist ──
    let filter = Filter::new()
        .address(core.bridgehub)
        .event_signature(IEcosystemEvents::SettlementLayerRegistered::SIGNATURE_HASH)
        .from_block(input.from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for SettlementLayerRegistered")?;
    let bridgehub = IBridgehubView::new(core.bridgehub, provider);
    let mut extra = Vec::new();
    for log in &logs {
        let Some(chain_id) = log.topics().get(1) else {
            continue;
        };
        let chain_id = U256::from_be_bytes(chain_id.0);
        if chain_id == U256::from(core.l1_chain_id) {
            continue;
        }
        if bridgehub
            .whitelistedSettlementLayers(chain_id)
            .block(to_block.into())
            .call()
            .await?
        {
            extra.push(chain_id);
        }
    }
    if extra.is_empty() {
        result.report_ok("L1 is the only whitelisted settlement layer");
    }
    for chain_id in extra {
        result.report_error(&format!(
            "chain {chain_id} is whitelisted as a settlement layer. Every chain in this \
             ecosystem can be migrated onto it, so whoever controls it controls them."
        ));
    }

    // ── pause flags ──
    for (label, address) in [
        ("L1Bridgehub", core.bridgehub),
        ("L1Nullifier", core.nullifier),
        ("L1ChainAssetHandler", core.chain_asset_handler),
    ] {
        if let Some(paused) = probe(
            contracts::IPausableView::new(address, provider)
                .paused()
                .block(to_block.into())
                .call()
                .await,
            &format!("{label}.paused()"),
        )
        .await?
        {
            result.expect(
                !paused,
                &format!("{label} is not paused"),
                &format!("{label} is paused"),
            );
        }
    }
    let migration_paused = IChainAssetHandlerView::new(core.chain_asset_handler, provider)
        .migrationPaused()
        .block(to_block.into())
        .call()
        .await?;
    result.expect(
        !migration_paused,
        "chain migrations are not paused",
        "chain migrations are paused on the ChainAssetHandler",
    );

    // ── validator sets ──
    // The counts alone say nothing: with a zero threshold one extra shared
    // validator is the whole sequencer.
    let timelock = ITimelockView::new(ctm.validator_timelock, provider);
    if let Some(count) = probe(
        timelock
            .sharedValidatorsCount()
            .block(to_block.into())
            .call()
            .await,
        "timelock.sharedValidatorsCount()",
    )
    .await?
    {
        for index in 0..count.to::<u64>() {
            let member = timelock
                .sharedValidatorsMember(U256::from(index))
                .block(to_block.into())
                .call()
                .await?;
            result.print_info(&format!("  shared validator {index}: {member}"));
        }
    }

    Ok(())
}

async fn verify_roles(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    expected: &[Expected],
    to_block: u64,
) -> anyhow::Result<()> {
    let mut report = roles::RoleReport::default();

    for entry in expected {
        // Implementations behind proxies hold no live roles.
        if entry.label.ends_with(" impl") {
            continue;
        }
        roles::collect_ownable(provider, &mut report, entry.label, entry.address, to_block).await?;
    }
    roles::collect_governance(provider, &mut report, core.governance, to_block).await?;
    roles::collect_chain_admin(provider, &mut report, core.chain_admin, to_block).await?;
    roles::collect_admin(
        provider,
        &mut report,
        "L1Bridgehub",
        core.bridgehub,
        core.chain_admin,
        input.from_block,
        to_block,
    )
    .await?;
    let ctm_admin = contracts::IBridgehubView::new(ctm.ctm, provider)
        .admin()
        .block(to_block.into())
        .call()
        .await
        .context("ctm.admin()")?;
    roles::collect_admin(
        provider,
        &mut report,
        "ChainTypeManager",
        ctm.ctm,
        ctm_admin,
        input.from_block,
        to_block,
    )
    .await?;
    // Chain admins control DA, fees and the transaction filterer, so they
    // belong in the same audit as the ecosystem roles.
    let bridgehub = IBridgehubView::new(core.bridgehub, provider);
    for chain_id in bridgehub
        .getAllZKChainChainIDs()
        .block(to_block.into())
        .call()
        .await?
    {
        let chain = bridgehub
            .getZKChain(chain_id)
            .block(to_block.into())
            .call()
            .await?;
        let admin = contracts::IZKChainView::new(chain, provider)
            .getAdmin()
            .block(to_block.into())
            .call()
            .await?;
        let label: &'static str = Box::leak(format!("chain {chain_id}").into_boxed_str());
        roles::collect_admin(
            provider,
            &mut report,
            label,
            chain,
            admin,
            input.from_block,
            to_block,
        )
        .await?;
        // The admin is itself usually a ChainAdmin contract with an owner.
        let admin_label: &'static str =
            Box::leak(format!("chain {chain_id} ChainAdmin").into_boxed_str());
        roles::collect_ownable(provider, &mut report, admin_label, admin, to_block).await?;
    }
    roles::classify_holders(provider, &mut report, to_block).await?;

    for (holder, holdings) in report.by_holder() {
        if holder == Address::ZERO {
            continue;
        }
        let kind = if report.is_eoa(&holder) {
            "EOA"
        } else {
            "contract"
        };
        let code_hash = if report.is_eoa(&holder) {
            String::new()
        } else {
            // Printed so a reviewer can recognise a known multisig
            // implementation. Whether that multisig is the right one is the
            // operator's call, which is what --expected-ecosystem-owner is for.
            format!(
                "  code {}",
                keccak256(
                    provider
                        .get_code_at(holder)
                        .block_id(to_block.into())
                        .await?
                )
            )
        };
        result.print_info(&format!(
            "  {holder}  ({kind}, {} role(s)){code_hash}",
            holdings.len()
        ));
        for holding in holdings {
            result.print_info(&format!(
                "      {:<24} {}",
                holding.role.label(),
                holding.contract
            ));
        }
    }

    // Every internal role is decided by the deploy scripts, so each one is an
    // assertion. This is what stops a byte-exact deployment whose owner is
    // somebody else's Safe from passing.
    let proxy_admin_labels: Vec<(&'static str, Address)> = Vec::new();
    for (contract, role, expected) in expected_role_holders(core, ctm, &proxy_admin_labels) {
        let Some(actual) = report
            .holdings
            .iter()
            .find(|holding| holding.contract == contract && holding.role == role)
        else {
            result.report_error(&format!(
                "{contract}.{} was never read, so it cannot be checked",
                role.label()
            ));
            continue;
        };
        result.expect(
            actual.holder == expected,
            &format!("{contract}.{} is {expected}", role.label()),
            &format!(
                "{contract}.{} is {} but the deploy scripts put it at {expected}",
                role.label(),
                actual.holder
            ),
        );
    }

    // The root of the ecosystem: whoever holds these controls everything above
    // through Governance, so it is the one thing the tool cannot derive.
    let governance = IGovernanceView::new(core.governance, provider);
    let min_delay = governance.minDelay().block(to_block.into()).call().await?;
    let security_council = governance
        .securityCouncil()
        .block(to_block.into())
        .call()
        .await?;
    result.print_info(&format!(
        "  Governance minDelay {min_delay}s, securityCouncil {security_council}"
    ));

    match input.expected_ecosystem_owner {
        Some(expected) => {
            for (contract, address) in [
                ("Governance", core.governance),
                ("ChainAdminOwnable", core.chain_admin),
            ] {
                let actual = IOwnableView::new(address, provider)
                    .owner()
                    .block(to_block.into())
                    .call()
                    .await?;
                result.expect(
                    actual == expected,
                    &format!("{contract}.owner is the expected ecosystem owner {expected}"),
                    &format!("{contract}.owner is {actual}, expected {expected}"),
                );
            }
        }
        None => result.report_warn(
            "--expected-ecosystem-owner was not supplied, so the root of the ecosystem is \
             unverified: whoever owns Governance and ChainAdminOwnable controls every contract \
             above through them, and a deployment that is byte-exact in every other respect can \
             still be owned by the wrong party.",
        ),
    }
    match input.expected_security_council {
        Some(expected) => {
            result.expect(
                security_council == expected,
                &format!("Governance.securityCouncil is {expected}"),
                &format!("Governance.securityCouncil is {security_council}, expected {expected}"),
            );
        }
        None => result.report_warn(
            "--expected-security-council was not supplied. The security council can \
             `executeInstant`, bypassing the delay entirely, so it is as privileged as the owner.",
        ),
    }
    match input.expected_min_delay {
        Some(expected) => {
            result.expect(
                min_delay == expected,
                &format!("Governance.minDelay is {expected}s"),
                &format!("Governance.minDelay is {min_delay}s, expected {expected}s"),
            );
        }
        None if min_delay.is_zero() => result.report_warn(
            "Governance.minDelay is 0, so a scheduled operation can be executed in the same \
             block it is scheduled. Pass --expected-min-delay to assert the intended value.",
        ),
        None => {}
    }

    // A second Governance owning the CTM (the `reuseGovAndAdmin = false` path)
    // would be invisible otherwise: only the bridgehub's is discovered.
    let ctm_owner = IOwnableView::new(ctm.ctm, provider)
        .owner()
        .block(to_block.into())
        .call()
        .await?;
    result.expect(
        ctm_owner == core.governance,
        "the CTM and the bridgehub share one Governance",
        &format!(
            "the CTM is owned by {ctm_owner} but the bridgehub by {}: this ecosystem has two \
             Governance contracts, and only the bridgehub's is verified here",
            core.governance
        ),
    );

    let stalled = report.stalled_handoffs();
    for holding in &stalled {
        result.report_error(&format!(
            "{}.{} is still {} — the two-step handoff was started and never accepted, so the \
             previous holder still controls it",
            holding.contract,
            holding.role.label(),
            holding.holder
        ));
    }
    if stalled.is_empty() {
        result.report_ok("no stalled ownership or adminship handoffs");
    }
    for holding in report.self_transfers() {
        result.report_warn(&format!(
            "{}.{} points at the current holder {} — a `transferOwnership(currentOwner)` \
             no-op left behind by the deploy scripts, harmless but worth clearing",
            holding.contract,
            holding.role.label(),
            holding.holder
        ));
    }

    // Every role that resolves to a key rather than a contract.
    let eoa_roles: Vec<_> = report
        .holdings
        .iter()
        .filter(|holding| !holding.role.is_pending() && report.is_eoa(&holding.holder))
        .collect();
    if eoa_roles.is_empty() {
        result.report_ok("no privileged role is held directly by an EOA");
    } else {
        result.report_warn(&format!(
            "{} role(s) are held by an EOA: {}",
            eoa_roles.len(),
            eoa_roles
                .iter()
                .map(|holding| format!("{}.{}", holding.contract, holding.role.label()))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    // A timelock with validators but no threshold, or a threshold with no
    // validators, is the ordering mistake that bricks the first commit.
    let timelock = ITimelockView::new(ctm.validator_timelock, provider);
    if let Some(threshold) = probe(
        timelock
            .sharedSigningThreshold()
            .block(to_block.into())
            .call()
            .await,
        "timelock.sharedSigningThreshold()",
    )
    .await?
    {
        let validators = timelock
            .sharedValidatorsCount()
            .block(to_block.into())
            .call()
            .await?;
        let delay = timelock
            .executionDelay()
            .block(to_block.into())
            .call()
            .await?;
        result.print_info(&format!(
            "  MultisigCommitter: {validators} shared validator(s), threshold {threshold}, \
             executionDelay {delay}"
        ));
        result.expect(
            threshold <= validators,
            "shared signing threshold is reachable",
            &format!(
                "sharedSigningThreshold is {threshold} but only {validators} shared validator(s) \
                 are registered — the first commit reverts and nobody can sign it"
            ),
        );
        if threshold.is_zero() && !validators.is_zero() {
            result.report_warn(&format!(
                "{validators} shared validator(s) are registered but sharedSigningThreshold is 0, \
                 so MultisigCommitter accepts commits with no signatures. That is the intended \
                 posture until the set is final — raise the threshold once it is, and never \
                 before the validators exist."
            ));
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn verify_chains(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    rollup_da_manager: Option<Address>,
    cut_facets: &[contracts::FacetCut],
    index: &ArtifactIndex,
    code_cache: &mut CodeCache,
    to_block: u64,
) -> anyhow::Result<()> {
    let bh = IBridgehubView::new(core.bridgehub, provider);
    let chain_ids = bh
        .getAllZKChainChainIDs()
        .block(to_block.into())
        .call()
        .await?;
    if chain_ids.is_empty() {
        result.print_info("  no chains registered");
        return Ok(());
    }
    for chain_id in chain_ids {
        let address = bh
            .getZKChain(chain_id)
            .block(to_block.into())
            .call()
            .await?;
        let chain = contracts::IZKChainView::new(address, provider);
        // Comparing a chain against a CTM that is not its own would produce
        // misleading mismatches rather than a real finding.
        let chain_ctm = bh
            .chainTypeManager(chain_id)
            .block(to_block.into())
            .call()
            .await?;
        if chain_ctm != ctm.ctm {
            result.report_error(&format!(
                "chain {chain_id} belongs to CTM {chain_ctm}, not the one being verified \
                 ({}); its parameters are not covered by this report",
                ctm.ctm
            ));
            continue;
        }
        let protocol_version = chain
            .getProtocolVersion()
            .block(to_block.into())
            .call()
            .await?;
        let verifier = chain.getVerifier().block(to_block.into()).call().await?;
        let stored_zero = chain
            .storedBatchHash(U256::ZERO)
            .block(to_block.into())
            .call()
            .await?;
        let da = chain
            .getDAValidatorPair()
            .block(to_block.into())
            .call()
            .await?;
        result.print_info(&format!(
            "  chain {chain_id} at {address}: admin {}, DA ({} scheme {})",
            chain.getAdmin().block(to_block.into()).call().await?,
            da._0,
            da._1
        ));
        result.expect(
            protocol_version == ctm.protocol_version,
            &format!("chain {chain_id} is on the CTM's protocol version"),
            &format!(
                "chain {chain_id} is on {protocol_version}, the CTM is on {}",
                ctm.protocol_version
            ),
        );
        result.expect(
            verifier == ctm.verifier,
            &format!("chain {chain_id} uses the CTM's verifier"),
            &format!(
                "chain {chain_id} uses {verifier}, the CTM registers {}",
                ctm.verifier
            ),
        );
        // `facets()` rather than `facetAddresses()`: an equal address set does
        // not prove the selector-to-facet routing matches the cut.
        let live_facets = chain.facets().block(to_block.into()).call().await?;
        let mut live_routing: Vec<(Address, Vec<[u8; 4]>)> = live_facets
            .iter()
            .map(|facet| {
                let mut selectors: Vec<[u8; 4]> =
                    facet.selectors.iter().map(|selector| selector.0).collect();
                selectors.sort();
                (facet.addr, selectors)
            })
            .collect();
        live_routing.sort();
        let mut cut_routing: Vec<(Address, Vec<[u8; 4]>)> = cut_facets
            .iter()
            .map(|cut| {
                let mut selectors: Vec<[u8; 4]> =
                    cut.selectors.iter().map(|selector| selector.0).collect();
                selectors.sort();
                (cut.facet, selectors)
            })
            .collect();
        cut_routing.sort();
        result.expect(
            live_routing == cut_routing,
            &format!("chain {chain_id} routes every selector to the facet the cut names"),
            &format!(
                "chain {chain_id} selector routing differs from the chain creation cut ({} live \
                 facets vs {} in the cut)",
                live_routing.len(),
                cut_routing.len()
            ),
        );

        // The diamond proxy itself is code too, and nothing checked it.
        let diamond_code = code_cache.get(provider, address, to_block).await?;
        match index
            .identify(&diamond_code)
            .into_iter()
            .find(|(artifact, _)| artifact.name == "DiamondProxy")
        {
            Some((_, kind)) => result.report_ok(&format!(
                "chain {chain_id} diamond proxy is DiamondProxy ({})",
                kind.label()
            )),
            None => result.report_error(&format!(
                "chain {chain_id} at {address} is not a DiamondProxy from this build"
            )),
        }

        let filterer = chain
            .getTransactionFilterer()
            .block(to_block.into())
            .call()
            .await?;
        if filterer != Address::ZERO {
            result.report_warn(&format!(
                "chain {chain_id} has a transaction filterer at {filterer}: it can reject \
                 priority transactions, which is a censorship lever"
            ));
        }
        result.expect(
            !chain
                .isDiamondStorageFrozen()
                .block(to_block.into())
                .call()
                .await?,
            &format!("chain {chain_id} diamond storage is not frozen"),
            &format!("chain {chain_id} diamond storage is frozen"),
        );
        let pending_admin = chain
            .getPendingAdmin()
            .block(to_block.into())
            .call()
            .await?;
        result.expect(
            pending_admin == Address::ZERO,
            &format!("chain {chain_id} has no pending admin"),
            &format!("chain {chain_id} has a pending admin {pending_admin}"),
        );
        result.expect(
            chain.getBridgehub().block(to_block.into()).call().await? == core.bridgehub
                && chain
                    .getChainTypeManager()
                    .block(to_block.into())
                    .call()
                    .await?
                    == ctm.ctm
                && chain.getChainId().block(to_block.into()).call().await? == chain_id,
            &format!("chain {chain_id} agrees on its own bridgehub, CTM and chain id"),
            &format!("chain {chain_id} disagrees with the bridgehub about its own identity"),
        );
        result.expect(
            chain
                .getPriorityTxMaxGasLimit()
                .block(to_block.into())
                .call()
                .await?
                == U256::from(PRIORITY_TX_MAX_GAS_LIMIT),
            &format!("chain {chain_id} priority tx gas limit is {PRIORITY_TX_MAX_GAS_LIMIT}"),
            &format!("chain {chain_id} priority tx gas limit is not the Config.sol value"),
        );
        result.print_info(&format!(
            "  chain {chain_id} pubdata pricing mode {}",
            chain
                .getPubdataPricingMode()
                .block(to_block.into())
                .call()
                .await?
        ));
        let base_token = chain
            .getBaseTokenAssetId()
            .block(to_block.into())
            .call()
            .await?;
        // Two copies of the same value drive different halves of fee and
        // bridge processing; if they diverge, L1 routes a different asset than
        // the chain thinks it has.
        let bridgehub_base_token = bh
            .baseTokenAssetId(chain_id)
            .block(to_block.into())
            .call()
            .await?;
        result.expect(
            base_token == bridgehub_base_token,
            &format!("chain {chain_id} base token agrees with the bridgehub"),
            &format!(
                "chain {chain_id} reports base token {base_token} but the bridgehub has \
                 {bridgehub_base_token}"
            ),
        );
        result.expect(
            bh.assetIdIsRegistered(base_token)
                .block(to_block.into())
                .call()
                .await?,
            &format!("chain {chain_id} base token asset id is registered on the bridgehub"),
            &format!("chain {chain_id} base token {base_token} is not a registered asset id"),
        );
        result.expect(
            stored_zero == ctm.stored_batch_zero,
            &format!("chain {chain_id} genesis batch matches the CTM's storedBatchZero"),
            &format!(
                "chain {chain_id} storedBatchHash(0) is {stored_zero}, the CTM's storedBatchZero \
                 is {} — the chain was created under different creation params",
                ctm.stored_batch_zero
            ),
        );
        result.expect(
            bh.settlementLayer(chain_id)
                .block(to_block.into())
                .call()
                .await?
                == U256::from(core.l1_chain_id),
            &format!("chain {chain_id} settles on L1"),
            &format!("chain {chain_id} does not settle on L1"),
        );
        // `Admin.makePermanentRollup` re-checks the chain's live DA pair
        // against the manager, so a chain running an un-whitelisted pair can
        // never lock itself in as a rollup.
        if let Some(manager) = rollup_da_manager {
            let allowed = IRollupDAManagerView::new(manager, provider)
                .isPairAllowed(da._0, da._1)
                .block(to_block.into())
                .call()
                .await?;
            if !allowed {
                result.report_warn(&format!(
                    "chain {chain_id} runs DA pair ({}, scheme {}), which the RollupDAManager \
                     does not allow — makePermanentRollup() would revert \
                     InvalidDAForPermanentRollup",
                    da._0, da._1
                ));
            }
        }
    }
    Ok(())
}

/// Immutables whose value is fully determined by what was discovered on
/// chain, keyed by declaration name. Anything not listed here is printed for
/// the reader rather than asserted.
fn immutable_expectations(
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
) -> Vec<(&'static str, FixedBytes<32>)> {
    let address = |value: Address| FixedBytes::<32>::left_padding_from(value.as_slice());
    let number = |value: U256| FixedBytes::<32>::from(value.to_be_bytes::<32>());

    let mut out = vec![
        ("BRIDGE_HUB", address(core.bridgehub)),
        ("BRIDGEHUB", address(core.bridgehub)),
        ("L1_CHAIN_ID", number(U256::from(core.l1_chain_id))),
        // Recomputed rather than taken from the chain: a consistent but
        // foreign asset id would otherwise pass every cross-contract check.
        ("ETH_TOKEN_ASSET_ID", eth_token_asset_id(core.l1_chain_id)),
        ("BASE_TOKEN_ASSET_ID", eth_token_asset_id(core.l1_chain_id)),
        ("L1_NULLIFIER", address(core.nullifier)),
        ("ASSET_ROUTER", address(core.asset_router)),
        ("L1_ASSET_ROUTER", address(core.asset_router)),
        ("MESSAGE_ROOT", address(core.message_root)),
        ("CHAIN_ASSET_HANDLER", address(core.chain_asset_handler)),
        // The L2 interop center lives at a fixed built-in address; comparing
        // against what the CTM reports would compare it to itself.
        ("INTEROP_CENTER", address(L2_INTEROP_CENTER_ADDR)),
        ("L1_BYTECODES_SUPPLIER", address(ctm.bytecodes_supplier)),
        (
            "PERMISSIONLESS_VALIDATOR",
            address(ctm.permissionless_validator),
        ),
        ("PLONK_VERIFIER", address(ctm.plonk_verifier)),
        (
            "IS_ZKSYNC_OS",
            number(U256::from(u8::from(ctm.is_zksync_os))),
        ),
        (
            "MAX_NUMBER_OF_ZK_CHAINS",
            number(U256::from(input.expected_max_number_of_zk_chains)),
        ),
        ("ERA_CHAIN_ID", number(core.era_chain_id)),
        // `Config.sol` fixes these for every deployment in this release.
        ("PAUSE_DEPOSITS_TIME_WINDOW_START", FixedBytes::ZERO),
        ("CHAIN_MIGRATION_TIME_WINDOW_START", FixedBytes::ZERO),
        (
            "COMMIT_TIMESTAMP_NOT_OLDER",
            number(U256::from(if core.l1_chain_id == MAINNET_CHAIN_ID {
                MAINNET_COMMIT_TIMESTAMP_NOT_OLDER
            } else {
                TESTNET_COMMIT_TIMESTAMP_NOT_OLDER
            })),
        ),
        // A fresh ecosystem has no legacy gateway and no Era chain.
        ("ERA_GATEWAY_CHAIN_ID", FixedBytes::ZERO),
        ("ERA_DIAMOND_PROXY", address(core.era_diamond_proxy)),
    ];
    // Getting WETH wrong bakes a foreign token into the asset router and the
    // native token vault, and is only fixable by an implementation upgrade.
    if let Some(weth) = input.expected_weth {
        out.push(("L1_WETH_TOKEN", address(weth)));
        out.push(("WETH_TOKEN", address(weth)));
    }
    if let Some(era_chain_id) = input.expected_era_chain_id {
        out.retain(|(name, _)| *name != "ERA_CHAIN_ID");
        out.push(("ERA_CHAIN_ID", number(U256::from(era_chain_id))));
    }
    out
}

/// Chain ids, delays and flags read best as numbers; wiring reads best as
/// addresses; asset ids and hashes as hex.
fn render_immutable(value: &artifact_index::ImmutableValue) -> String {
    let number = value.as_u256();
    if number <= U256::from(u64::MAX) {
        return format!("{number}");
    }
    match value.as_address() {
        Some(address) => format!("{address}"),
        None => format!("{}", value.as_b256()),
    }
}

/// `AddressAliasHelper.applyL1ToL2Alias`.
fn apply_l1_to_l2_alias(address: Address) -> Address {
    const OFFSET: [u8; 20] = alloy::hex!("1111000000000000000000000000000000001111");
    let sum: U256 =
        U256::from_be_slice(address.as_slice()).wrapping_add(U256::from_be_slice(&OFFSET));
    // Addresses wrap at 2^160, which is how 0xFF65… aliases down to 0x1076….
    let mask: U256 = (U256::from(1u64) << 160) - U256::from(1u64);
    Address::from_slice(&(sum & mask).to_be_bytes::<32>()[12..])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pinned against the live Sepolia ecosystem, where every contract that
    /// carries `ETH_TOKEN_ASSET_ID` reports this value.
    #[test]
    fn eth_asset_id_is_recomputed_not_read() {
        assert_eq!(
            eth_token_asset_id(11155111),
            FixedBytes::new(alloy::hex!(
                "6337a96bd2cd359fa0bae3bbedfca736753213c95037ae158c5fa7c048ae2112"
            ))
        );
        // Chain id is part of the preimage, so a foreign ecosystem's id cannot
        // pass as this one's.
        assert_ne!(eth_token_asset_id(1), eth_token_asset_id(11155111));
    }

    /// Every contract whose owner or admin the deploy scripts set must have an
    /// expectation, or it silently reverts to being printed rather than
    /// checked — which is the gap this section exists to close.
    #[test]
    fn every_script_assigned_role_has_an_expectation() {
        let core = discovery::CoreAddresses {
            bridgehub: Address::repeat_byte(1),
            governance: Address::repeat_byte(2),
            chain_admin: Address::repeat_byte(3),
            proxy_admin: Address::repeat_byte(4),
            message_root: Address::ZERO,
            chain_asset_handler: Address::ZERO,
            ctm_deployment_tracker: Address::ZERO,
            chain_registration_sender: Address::ZERO,
            asset_router: Address::ZERO,
            nullifier: Address::ZERO,
            native_token_vault: Address::ZERO,
            interop_handler: Address::ZERO,
            bridged_token_beacon: Address::ZERO,
            bridged_standard_erc20: Address::ZERO,
            l1_chain_id: 1,
            max_number_of_zk_chains: U256::from(100),
            era_chain_id: U256::from(324),
            l1_weth: Address::ZERO,
            eth_token_asset_id: FixedBytes::ZERO,
            era_diamond_proxy: Address::ZERO,
        };
        let ctm = discovery::CtmAddresses {
            ctm: Address::repeat_byte(5),
            is_zksync_os: true,
            protocol_version: U256::ZERO,
            semver: (0, 33, 0),
            genesis_upgrade: Address::ZERO,
            default_upgrade: Address::ZERO,
            server_notifier: Address::ZERO,
            server_notifier_proxy_admin: Address::ZERO,
            validator_timelock: Address::ZERO,
            bytecodes_supplier: Address::ZERO,
            permissionless_validator: Address::ZERO,
            interop_center: Address::ZERO,
            verifier: Address::ZERO,
            plonk_verifier: Address::ZERO,
            verifier_is_testnet: false,
            verification_key_hash: FixedBytes::ZERO,
            stored_batch_zero: FixedBytes::ZERO,
            initial_cut_hash: FixedBytes::ZERO,
            initial_force_deployment_hash: FixedBytes::ZERO,
        };
        let expectations = expected_role_holders(&core, &ctm, &[("L1Bridgehub", Address::ZERO)]);

        for contract in [
            "L1Bridgehub",
            "ChainTypeManager",
            "L1AssetRouter",
            "L1Nullifier",
            "L1InteropHandler",
            "CTMDeploymentTracker",
            "L1ChainAssetHandler",
            "RollupDAManager",
            "ProxyAdmin",
            "L1NativeTokenVault",
            "ValidatorTimelock",
            "BridgedTokenBeacon",
            "ChainRegistrationSender",
            "ServerNotifier",
            "ServerNotifier ProxyAdmin",
        ] {
            assert!(
                expectations
                    .iter()
                    .any(|(name, role, _)| name == contract && *role == Role::Owner),
                "{contract} has no expected owner"
            );
        }
        // The two contracts whose admin the scripts set.
        for contract in ["L1Bridgehub", "ChainTypeManager"] {
            assert!(expectations
                .iter()
                .any(|(name, role, _)| name == contract && *role == Role::Admin));
        }
        // ServerNotifier goes to ChainAdmin, not Governance.
        assert!(expectations
            .iter()
            .any(|(name, role, holder)| name == "ServerNotifier"
                && *role == Role::Owner
                && *holder == core.chain_admin));
    }

    #[test]
    fn aliases_like_the_solidity_helper() {
        // Governance 0xFF657F25… aliases to 0x10767F25… (wraps past 2^160).
        assert_eq!(
            apply_l1_to_l2_alias(Address::from(alloy::hex!(
                "FF657F253C0FbdE6A7DeCdc958F4153C1179D3aa"
            ))),
            Address::from(alloy::hex!("10767F253C0FbdE6A7DeCdc958F4153C1179E4BB"))
        );
    }
}
