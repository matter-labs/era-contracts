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
    IBridgehubView, IChainAssetHandlerView, IEcosystemEvents, IRollupDAManagerView,
    IServerNotifierView, ITimelockView,
};
use crate::deployment_verification::discovery::{
    address_at_slot, probe, EIP1967_IMPLEMENTATION_SLOT,
};

/// `L2_NATIVE_TOKEN_VAULT_ADDR`, the deployment-tracker leg of every NTV asset id.
const L2_NATIVE_TOKEN_VAULT_ADDR: Address =
    Address::new(alloy::hex!("0000000000000000000000000000000000010004"));
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
    ) -> anyhow::Result<alloy::primitives::Bytes> {
        if let Some(code) = self.0.get(&address) {
            return Ok(code.clone());
        }
        let code = provider
            .get_code_at(address)
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
    let index = load_artifacts(&mut result)?;

    result.print_section("Discovery");
    let core = discovery::discover_core(&provider, input.bridgehub).await?;
    result.expect(
        core.l1_chain_id == chain_id,
        &format!("Bridgehub L1_CHAIN_ID {} matches the RPC", core.l1_chain_id),
        &format!(
            "Bridgehub L1_CHAIN_ID is {} but the RPC reports chain {chain_id} — wrong network \
             or wrong bridgehub",
            core.l1_chain_id
        ),
    );

    let ctm_address = crate::common::l1_contracts::discover_ctm_proxy_with(
        &provider,
        input.bridgehub,
        input.from_block,
    )
    .await
    .context("discovering the CTM registered on the bridgehub")?;
    let ctm = discovery::discover_ctm(&provider, ctm_address).await?;
    result.print_info(&format!(
        "  bridgehub {}  ctm {}  protocol {}.{}.{} ({}) ",
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

    let params = chain_creation::fetch(&provider, ctm.ctm, input.from_block).await?;

    // ── bytecode ─────────────────────────────────────────────────────────
    result.print_section("Bytecode");
    let expected =
        build_expected_list(&provider, &mut code_cache, &core, &ctm, &params, &index).await?;
    let mut exact = 0usize;
    let mut metadata_only = 0usize;
    for entry in &expected {
        let code = code_cache.get(&provider, entry.address).await?;
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
        let code = code_cache.get(&provider, entry.address).await?;
        let Some((artifact, _)) = index.identify(&code).into_iter().next() else {
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
    verify_wiring(&provider, &mut result, &core, &ctm, &index).await?;

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
    )
    .await?;

    // ── verifier and genesis ─────────────────────────────────────────────
    result.print_section("Verifier and genesis");
    verify_verifier_and_genesis(&mut result, &input, &ctm, &params)?;

    // ── DA ───────────────────────────────────────────────────────────────
    result.print_section("Data availability");
    verify_da(&provider, &mut result, &input, &ctm, &index, &expected).await?;

    // ── roles ────────────────────────────────────────────────────────────
    result.print_section("Roles");
    verify_roles(&provider, &mut result, &input, &core, &ctm, &expected).await?;

    // ── registered chains ────────────────────────────────────────────────
    result.print_section("Registered chains");
    let rollup_da_manager = expected
        .iter()
        .find(|entry| entry.label == "RollupDAManager")
        .map(|entry| entry.address);
    let cut_facet_addresses: Vec<Address> = params
        .diamond_cut
        .facetCuts
        .iter()
        .map(|cut| cut.facet)
        .collect();
    verify_chains(
        &provider,
        &mut result,
        &core,
        &ctm,
        rollup_da_manager,
        &cut_facet_addresses,
    )
    .await?;

    result.print_section("Summary");
    result.print_info(&format!(
        "{} error(s), {} warning(s)",
        result.errors, result.warnings
    ));
    result.ensure_success()
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
) -> anyhow::Result<Vec<Expected>> {
    let mut out: Vec<Expected> = Vec::new();
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
            continue;
        }
        add!(label, address, vec!["TransparentUpgradeableProxy"]);
        let implementation =
            address_at_slot(provider, address, EIP1967_IMPLEMENTATION_SLOT).await?;
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
    let facet_names = [
        "AdminFacet",
        "GettersFacet",
        "MailboxFacet",
        "ExecutorFacet",
        "MigratorFacet",
        "CommitterFacet",
    ];
    for (position, cut) in params.diamond_cut.facetCuts.iter().enumerate() {
        let label: &'static str = facet_names
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
    if let Some(address) =
        immutable_address(index, provider, code_cache, params, 0, "ROLLUP_DA_MANAGER").await?
    {
        add!("RollupDAManager", address, vec!["RollupDAManager"]);
    }
    if let Some(address) =
        immutable_address(index, provider, code_cache, params, 2, "EIP_7702_CHECKER").await?
    {
        add!("EIP7702Checker", address, vec!["EIP7702Checker"]);
    }

    Ok(out)
}

/// Reads one named immutable out of a deployed facet.
async fn immutable_address(
    index: &ArtifactIndex,
    provider: &AlloyProvider,
    code_cache: &mut CodeCache,
    params: &chain_creation::ChainCreationParams,
    facet_position: usize,
    immutable: &str,
) -> anyhow::Result<Option<Address>> {
    let Some(cut) = params.diamond_cut.facetCuts.get(facet_position) else {
        return Ok(None);
    };
    let code = code_cache.get(provider, cut.facet).await?;
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
) -> anyhow::Result<()> {
    let wiring = discovery::read_bridge_wiring(provider, core).await?;
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
    let cah_message_root = cah.MESSAGE_ROOT().call().await?;
    let cah_asset_router = cah.ASSET_ROUTER().call().await?;
    check(
        cah_message_root == core.message_root && cah_asset_router == core.asset_router,
        "L1ChainAssetHandler.setAddresses was run",
        format!("messageRoot {cah_message_root}, assetRouter {cah_asset_router}"),
    );

    let notifier_ctm = IServerNotifierView::new(ctm.server_notifier, provider)
        .chainTypeManager()
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
    let registered = bh.chainTypeManagerIsRegistered(ctm.ctm).call().await?;
    check(
        registered,
        "Bridgehub.addChainTypeManager was run",
        "CTM is not registered; createNewChain reverts CTMNotRegistered".to_string(),
    );

    let asset_id = bh.ctmAssetIdFromAddress(ctm.ctm).call().await?;
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
    let back = bh.ctmAssetIdToAddress(asset_id).call().await?;
    check(
        back == ctm.ctm,
        "Bridgehub CTM asset id round-trips",
        format!("got {back}"),
    );

    let ar = contracts::IAssetRouterView::new(core.asset_router, provider);
    let ctm_handler = ar.assetHandlerAddress(asset_id).call().await?;
    check(
        ctm_handler == core.chain_asset_handler,
        "AssetRouter routes the CTM asset to the ChainAssetHandler",
        format!("got {ctm_handler}"),
    );
    let eth_handler = ar
        .assetHandlerAddress(core.eth_token_asset_id)
        .call()
        .await?;
    check(
        eth_handler == core.native_token_vault,
        "AssetRouter routes ETH to the NativeTokenVault (registerEthToken was run)",
        format!("got {eth_handler}"),
    );

    let l1_whitelisted = bh
        .whitelistedSettlementLayers(U256::from(core.l1_chain_id))
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
    if bh.assetIdIsRegistered(FixedBytes::ZERO).call().await? {
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
) -> anyhow::Result<()> {
    result.print_info(&format!(
        "  parameters last set at block {}",
        params.block_number
    ));

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
        // `DiamondInit` takes three EraVM bytecode hashes that ZKsync OS
        // does not use; a non-zero here means the wrong VM's genesis config.
        let zero_init = params
            .diamond_cut
            .initCalldata
            .iter()
            .all(|byte| *byte == 0);
        result.expect(
            zero_init,
            "diamondCut.initCalldata is all zero (no EraVM bytecode hashes)",
            &format!(
                "got 0x{}",
                alloy::hex::encode(&params.diamond_cut.initCalldata)
            ),
        );
    }

    // ── the diamond cut ──────────────────────────────────────────────────
    let expected_freezable = [false, false, true, true, false, true];
    let mut seen: HashSet<[u8; 4]> = HashSet::new();
    let mut duplicates = 0usize;
    for (position, cut) in params.diamond_cut.facetCuts.iter().enumerate() {
        let code = code_cache.get(provider, cut.facet).await?;
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

    verify_zk_token_asset_id(provider, result, input, core, data.zkTokenAssetId).await?;

    // L2 implementations that every new chain force-deploys.
    for entry in force_deployment_entries(data)? {
        match verify_bytecode_info(index, entry.artifact, &entry.implementation) {
            BytecodeInfoVerdict::Exact => result.report_ok(&format!(
                "forceDeployments.{} = {} (exact)",
                entry.field, entry.artifact
            )),
            BytecodeInfoVerdict::MetadataOnly => result.report_warn(&format!(
                "forceDeployments.{}: {} has the right length ({} bytes) and the local build is \
                 the same code, but the blake2s/keccak differ because they hash the CBOR \
                 metadata trailer. Consistent with this checkout, not independently reproducible.",
                entry.field, entry.artifact, entry.implementation.length
            )),
            BytecodeInfoVerdict::Mismatch { local } => result.report_error(&format!(
                "forceDeployments.{}: on chain is {} bytes (blake {}), local {} is {} bytes \
                 (blake {})",
                entry.field,
                entry.implementation.length,
                entry.implementation.blake,
                entry.artifact,
                local.length,
                local.blake
            )),
            BytecodeInfoVerdict::MissingArtifact => result.report_error(&format!(
                "forceDeployments.{}: no artifact named {} in the local build",
                entry.field, entry.artifact
            )),
        }
    }
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

async fn verify_da(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    ctm: &discovery::CtmAddresses,
    _index: &ArtifactIndex,
    expected: &[Expected],
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
        .from_block(input.from_block);
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
    for (validator, scheme) in &allowed {
        result.print_info(&format!("  allowed DA pair: {validator} scheme {scheme}"));
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

async fn verify_roles(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    input: &VerifyDeploymentInput,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    expected: &[Expected],
) -> anyhow::Result<()> {
    let mut report = roles::RoleReport::default();

    for entry in expected {
        // Implementations behind proxies hold no live roles.
        if entry.label.ends_with(" impl") {
            continue;
        }
        roles::collect_ownable(provider, &mut report, entry.label, entry.address).await?;
    }
    roles::collect_governance(provider, &mut report, core.governance).await?;
    roles::collect_chain_admin(provider, &mut report, core.chain_admin).await?;
    roles::collect_admin(
        provider,
        &mut report,
        "L1Bridgehub",
        core.bridgehub,
        core.chain_admin,
        input.from_block,
    )
    .await?;
    let ctm_admin = contracts::IBridgehubView::new(ctm.ctm, provider)
        .admin()
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
    )
    .await?;
    roles::classify_holders(provider, &mut report).await?;

    for (holder, holdings) in report.by_holder() {
        if holder == Address::ZERO {
            continue;
        }
        let kind = if report.is_eoa(&holder) {
            "EOA"
        } else {
            "contract"
        };
        result.print_info(&format!("  {holder}  ({kind}, {} role(s))", holdings.len()));
        for holding in holdings {
            result.print_info(&format!(
                "      {:<24} {}",
                holding.role.label(),
                holding.contract
            ));
        }
    }

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
        timelock.sharedSigningThreshold().call().await,
        "timelock.sharedSigningThreshold()",
    )
    .await?
    {
        let validators = timelock.sharedValidatorsCount().call().await?;
        let delay = timelock.executionDelay().call().await?;
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
    }
    Ok(())
}

async fn verify_chains(
    provider: &AlloyProvider,
    result: &mut VerificationResult,
    core: &discovery::CoreAddresses,
    ctm: &discovery::CtmAddresses,
    rollup_da_manager: Option<Address>,
    cut_facet_addresses: &[Address],
) -> anyhow::Result<()> {
    let bh = IBridgehubView::new(core.bridgehub, provider);
    let chain_ids = bh.getAllZKChainChainIDs().call().await?;
    if chain_ids.is_empty() {
        result.print_info("  no chains registered");
        return Ok(());
    }
    for chain_id in chain_ids {
        let address = bh.getZKChain(chain_id).call().await?;
        let chain = contracts::IZKChainView::new(address, provider);
        let protocol_version = chain.getProtocolVersion().call().await?;
        let verifier = chain.getVerifier().call().await?;
        let stored_zero = chain.storedBatchHash(U256::ZERO).call().await?;
        let da = chain.getDAValidatorPair().call().await?;
        result.print_info(&format!(
            "  chain {chain_id} at {address}: admin {}, DA ({} scheme {})",
            chain.getAdmin().call().await?,
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
        let facets = chain.facetAddresses().call().await?;
        let cut_facets: Vec<Address> = cut_facet_addresses.to_vec();
        let mut live = facets.clone();
        live.sort();
        let mut expected_facets = cut_facets;
        expected_facets.sort();
        result.expect(
            live == expected_facets,
            &format!("chain {chain_id} runs the CTM's chain-creation facet set"),
            &format!(
                "chain {chain_id} facets {live:?} differ from the chain-creation cut \
                 {expected_facets:?} — the chain was upgraded, or created under other params"
            ),
        );
        let base_token = chain.getBaseTokenAssetId().call().await?;
        result.expect(
            bh.assetIdIsRegistered(base_token).call().await?,
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
            bh.settlementLayer(chain_id).call().await? == U256::from(core.l1_chain_id),
            &format!("chain {chain_id} settles on L1"),
            &format!("chain {chain_id} does not settle on L1"),
        );
        // `Admin.makePermanentRollup` re-checks the chain's live DA pair
        // against the manager, so a chain running an un-whitelisted pair can
        // never lock itself in as a rollup.
        if let Some(manager) = rollup_da_manager {
            let allowed = IRollupDAManagerView::new(manager, provider)
                .isPairAllowed(da._0, da._1)
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
        ("ETH_TOKEN_ASSET_ID", core.eth_token_asset_id),
        ("BASE_TOKEN_ASSET_ID", core.eth_token_asset_id),
        ("L1_NULLIFIER", address(core.nullifier)),
        ("ASSET_ROUTER", address(core.asset_router)),
        ("L1_ASSET_ROUTER", address(core.asset_router)),
        ("MESSAGE_ROOT", address(core.message_root)),
        ("CHAIN_ASSET_HANDLER", address(core.chain_asset_handler)),
        ("INTEROP_CENTER", address(ctm.interop_center)),
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
