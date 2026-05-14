use super::{
    call_list::CallList, fixed_force_deployment::FixedForceDeploymentsData,
    initialize_data_new_chain::InitializeDataNewChain, protocol_version::ProtocolVersion,
    set_new_version_upgrade,
};
use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::{
    expected_old_protocol_version_label, get_expected_new_protocol_version,
    get_expected_old_protocol_version, get_expected_old_protocol_version_for_ctm_flavor,
    utils::{
        compute_selector,
        facet_cut_set::{self, FacetCutSet, FacetInfo},
    },
};
use alloy::{
    hex,
    primitives::{Address, U256},
    providers::Provider,
    sol,
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;
use std::{
    collections::{HashMap, HashSet},
    str::FromStr,
};

pub struct GovernanceStage0Calls {
    pub calls: CallList,
}

pub struct GovernanceStage1Calls {
    pub calls: CallList,
}
pub struct GovernanceStage2Calls {
    pub calls: CallList,
}

sol! {
    function upgrade(address proxy, address implementation);
    function upgradeAndCall(address proxy, address implementation, bytes data);
    function initializeL1V31Upgrade();
    function setAssetTracker(address _l1AssetTracker);
    function setAddresses();
    function updateGuardians(address _newGuardians);

    // L2-side selectors carried as `l2Calldata` inside the new-Gateway
    // bring-up priority txs. Decoded by `verify_gateway_bring_up_calls` to
    // cross-check each priority tx targets the right contract on L2.
    function addChainTypeManager(address _chainTypeManager);
    function acceptOwnership();
    function setGatewaySettlementFee(uint256 _newFee);

    // Outer `requestL2TransactionDirect((...))` priority-tx struct. Layout
    // matches `L2TransactionRequestDirect` in `IBridgehubBase.sol`.
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
    function requestL2TransactionDirect(L2TransactionRequestDirect _request);

    #[sol(rpc)]
    contract BridgehubOwnerView {
        function owner() external view returns (address);
    }

    #[derive(Debug, PartialEq)]
    enum Action {
        Add,
        Replace,
        Remove
    }

    #[derive(Debug)]
    struct FacetCut {
        address facet;
        Action action;
        bool isFreezable;
        bytes4[] selectors;
    }

    #[derive(Debug)]
    struct DiamondCutData {
        FacetCut[] facetCuts;
        address initAddress;
        bytes initCalldata;
    }

    #[derive(Debug)]
    struct ChainCreationParams {
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes32 genesisBatchCommitment;
        DiamondCutData diamondCut;
        bytes forceDeploymentsData;
    }

    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams);

    #[derive(Debug)]
    struct CurrentFacet {
        address addr;
        bytes4[] selectors;
    }

    #[sol(rpc)]
    contract GettersFacet {
        function facets() external view returns (CurrentFacet[] memory);
    }
}

pub(crate) async fn verify_governance_stage_calls(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let stage0 = GovernanceStage0Calls {
        calls: CallList::parse(&artifact.governance_calls.stage0_calls),
    };
    stage0.verify_artifact(artifact, verifiers, result).await?;

    let stage1 = GovernanceStage1Calls {
        calls: CallList::parse(&artifact.governance_calls.stage1_calls),
    };
    stage1.verify_artifact(artifact, verifiers, result).await?;

    let stage2 = GovernanceStage2Calls {
        calls: CallList::parse(&artifact.governance_calls.stage2_calls),
    };
    stage2.verify_artifact(artifact, verifiers, result).await?;

    Ok(())
}

pub(crate) async fn verify_per_chain_protocol_versions(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Per-chain protocol versions ===");

    let mut expected_by_ctm = HashMap::new();
    let mut setup_errors = 0usize;
    for ctm in &artifact.ctms {
        let artifact_old_protocol_version = U256::from(ctm.contracts_config.old_protocol_version);
        let expected_old_protocol_version: U256 =
            get_expected_old_protocol_version_for_ctm_flavor(ctm.flavor).into();
        if artifact_old_protocol_version != expected_old_protocol_version {
            result.report_error(&format!(
                "{} CTM old protocol version must be {}, got {}",
                ctm.flavor.label(),
                expected_old_protocol_version_label(ctm.flavor),
                protocol_label(artifact_old_protocol_version)
            ));
            setup_errors += 1;
        }

        let Some(ctm_proxy) = required_ctm_address(
            ctm,
            &["state_transition", "chain_type_manager_proxy"],
            result,
        ) else {
            setup_errors += 1;
            continue;
        };

        if let Some((previous_flavor, _)) =
            expected_by_ctm.insert(ctm_proxy, (ctm.flavor, expected_old_protocol_version))
        {
            result.report_error(&format!(
                "CTM proxy {} is configured for both {} and {}",
                ctm_proxy,
                previous_flavor.label(),
                ctm.flavor.label()
            ));
            setup_errors += 1;
        }
    }

    if setup_errors > 0 {
        anyhow::bail!("{} errors", setup_errors);
    }

    let chain_ids = match verifiers
        .network_verifier
        .try_get_all_zk_chain_ids(verifiers.bridgehub_address)
        .await
    {
        Ok(chain_ids) => chain_ids,
        Err(err) => {
            result.report_warn(&format!(
                "Skipping per-chain protocol-version sweep; failed to fetch Bridgehub.getAllZKChainChainIDs(): {err}",
            ));
            return Ok(());
        }
    };

    if chain_ids.is_empty() {
        result.report_warn(
            "Bridgehub has no registered ZK chains; per-chain protocol-version sweep inspected nothing",
        );
        return Ok(());
    }

    let mut inspected = 0usize;
    for chain_id in chain_ids {
        let chain_ctm = match verifiers
            .network_verifier
            .try_get_chain_type_manager_from_bridgehub(verifiers.bridgehub_address, chain_id)
            .await
        {
            Ok(chain_ctm) => chain_ctm,
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping chain {chain_id}; failed to fetch Bridgehub.chainTypeManager(): {err}",
                ));
                continue;
            }
        };

        let Some((flavor, expected_protocol)) = expected_by_ctm.get(&chain_ctm).copied() else {
            result.report_warn(&format!(
                "Chain {chain_id} uses CTM {} which is not present in this v31 artifact",
                chain_ctm
            ));
            continue;
        };

        let diamond = match verifiers
            .network_verifier
            .try_get_chain_diamond_from_bridgehub(verifiers.bridgehub_address, chain_id)
            .await
        {
            Ok(diamond) if diamond != Address::ZERO => diamond,
            Ok(_) => {
                result.report_warn(&format!(
                    "Skipping chain {chain_id}; Bridgehub.getZKChain() returned zero address",
                ));
                continue;
            }
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping chain {chain_id}; failed to fetch Bridgehub.getZKChain(): {err}",
                ));
                continue;
            }
        };

        let protocol_version = match verifiers
            .network_verifier
            .try_get_chain_protocol_version(diamond)
            .await
        {
            Ok(protocol_version) => protocol_version,
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping chain {chain_id}; failed to fetch diamond protocol version from {diamond}: {err}",
                ));
                continue;
            }
        };

        inspected += 1;
        if protocol_version != expected_protocol {
            result.report_warn(&format!(
                "Chain {chain_id} on {} CTM has protocol version {}, expected {}",
                flavor.label(),
                protocol_label(protocol_version),
                protocol_label(expected_protocol)
            ));
        }
    }

    if inspected == 0 {
        result.report_warn("Per-chain protocol-version sweep did not inspect any chain diamonds");
    } else {
        result.report_ok(&format!(
            "Per-chain protocol-version sweep inspected {inspected} chain(s)"
        ));
    }

    Ok(())
}

/// Stage 1 call layout: 10 ecosystem-wide core calls (indices 0..=9), then 5
/// per-CTM calls repeated once per `[ctms.<flavor>]` section in artifact order:
/// timer deadline check, migrations-paused check, CTM proxy upgrade,
/// setChainCreationParams, setNewVersionUpgrade.
const STAGE1_PREFIX_LEN: usize = 10;
const STAGE1_PER_CTM_LEN: usize = 5;

/// Index of the per-CTM `ChainTypeManager` proxy upgrade within the
/// per-CTM block (offset relative to the start of that block).
const PER_CTM_OFFSET_CHECK_DEADLINE: usize = 0;
const PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED: usize = 1;
const PER_CTM_OFFSET_UPGRADE_CTM: usize = 2;
const PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS: usize = 3;
const PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE: usize = 4;

fn ctm_block_start(ctm_index: usize) -> usize {
    STAGE1_PREFIX_LEN + ctm_index * STAGE1_PER_CTM_LEN
}

impl GovernanceStage1Calls {
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        self.verify_call_shape(&artifact.ctms, verifiers, result)
            .await?;
        self.verify_artifact_payloads(artifact, verifiers, result)
            .await
    }

    async fn verify_call_shape(
        &self,
        ctms: &[CtmArtifact],
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 calls ===");

        const ACCEPT_ASSET_TRACKER_OWNERSHIP: usize = 7;
        const SET_ASSET_TRACKER: usize = 8;

        let mut errors = 0;
        for (index, target, method) in [
            // Upgrade Bridgehub proxy.
            (0, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 nullifier proxy.
            (1, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 asset router proxy.
            (2, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade native token vault proxy.
            (3, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade message root proxy and initialize v31 state.
            (
                4,
                "transparent_proxy_admin",
                "upgradeAndCall(address,address,bytes)",
            ),
            // Upgrade CTM deployment tracker proxy.
            (5, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade chain asset handler proxy.
            (6, "transparent_proxy_admin", "upgrade(address,address)"),
            // Accept AssetTracker ownership.
            (7, "asset_tracker_proxy", "acceptOwnership()"),
            // Wire AssetTracker into NativeTokenVault.
            (8, "native_token_vault", "setAssetTracker(address)"),
            // Cache MessageRoot / AssetRouter inside L1ChainAssetHandler.
            (9, "chain_asset_handler_proxy", "setAddresses()"),
        ] {
            errors += verify_call_by_name(&self.calls, index, target, method, verifiers, result);
        }

        for (ctm_index, ctm) in ctms.iter().enumerate() {
            let block = ctm_block_start(ctm_index);
            let timer_label = format!("{}.upgrade_timer", ctm.flavor.label());
            let validator_label = format!("{}.upgrade_stage_validator", ctm.flavor.label());
            let ctm_proxy_label = format!("{}.chain_type_manager_proxy", ctm.flavor.label());

            if let Some(timer) = required_ctm_address(
                ctm,
                &["deployed_addresses", "l1_governance_upgrade_timer"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_CHECK_DEADLINE,
                    timer,
                    &timer_label,
                    "checkDeadline()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }
            if let Some(validator) = required_ctm_address(
                ctm,
                &["deployed_addresses", "upgrade_stage_validator"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED,
                    validator,
                    &validator_label,
                    "checkMigrationsPaused()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }

            if let Some(ctm_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_proxy"],
                result,
            ) {
                let ctm_proxy_admin = verifiers.network_verifier.get_proxy_admin(ctm_proxy).await;
                let ctm_proxy_admin_label =
                    format!("{}.chain_type_manager_proxy_admin", ctm.flavor.label());
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_UPGRADE_CTM,
                    ctm_proxy_admin,
                    &ctm_proxy_admin_label,
                    "upgrade(address,address)",
                    verifiers,
                    result,
                );
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS,
                    ctm_proxy,
                    &ctm_proxy_label,
                    "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))",
                    verifiers,
                    result,
                );
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE,
                    ctm_proxy,
                    &ctm_proxy_label,
                    "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256,address)",
                    verifiers,
                    result,
                );
            } else {
                errors += 3;
            }
        }

        let expected_call_count = STAGE1_PREFIX_LEN + ctms.len() * STAGE1_PER_CTM_LEN;
        match self.calls.elems.len().cmp(&expected_call_count) {
            std::cmp::Ordering::Less => {
                result.report_error(&format!(
                    "Too few calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Greater => {
                result.report_error(&format!(
                    "Too many calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Equal => {}
        }

        // The accepted AssetTracker proxy must be the one wired into NativeTokenVault.
        if let (Some(accept_call), Some(set_asset_tracker_call)) = (
            self.calls.elems.get(ACCEPT_ASSET_TRACKER_OWNERSHIP),
            self.calls.elems.get(SET_ASSET_TRACKER),
        ) {
            match setAssetTrackerCall::abi_decode(&set_asset_tracker_call.data) {
                Ok(decoded) if decoded._l1AssetTracker == accept_call.target => {
                    result.report_ok(
                        "AssetTracker ownership target matches setAssetTracker argument",
                    );
                }
                Ok(decoded) => {
                    result.report_error(&format!(
                        "AssetTracker target mismatch: acceptOwnership targets {}, but setAssetTracker uses {}",
                        accept_call.target, decoded._l1AssetTracker
                    ));
                    errors += 1;
                }
                Err(err) => {
                    result.report_error(&format!("Failed to decode setAssetTracker call: {err}"));
                    errors += 1;
                }
            }
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }

    async fn verify_artifact_payloads(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 payloads ===");

        const UPGRADE_BRIDGEHUB: usize = 0;
        const UPGRADE_L1_NULLIFIER: usize = 1;
        const UPGRADE_L1_ASSET_ROUTER: usize = 2;
        const UPGRADE_NATIVE_TOKEN_VAULT: usize = 3;
        const UPGRADE_MESSAGE_ROOT: usize = 4;
        const UPGRADE_CTM_DEPLOYMENT_TRACKER: usize = 5;
        const UPGRADE_CHAIN_ASSET_HANDLER: usize = 6;

        let mut errors = 0;

        for (index, proxy_name, implementation_name) in [
            // Verify Bridgehub proxy upgrade payload.
            (
                UPGRADE_BRIDGEHUB,
                "bridgehub_proxy",
                "bridgehub_implementation_addr",
            ),
            // Verify L1 nullifier proxy upgrade payload.
            (
                UPGRADE_L1_NULLIFIER,
                "l1_nullifier_proxy",
                "l1_nullifier_implementation_addr",
            ),
            // Verify L1 asset router proxy upgrade payload.
            (
                UPGRADE_L1_ASSET_ROUTER,
                "l1_asset_router_proxy",
                "l1_asset_router_implementation_addr",
            ),
            // Verify native token vault proxy upgrade payload.
            (
                UPGRADE_NATIVE_TOKEN_VAULT,
                "native_token_vault",
                "native_token_vault_implementation_addr",
            ),
            // Verify CTM deployment tracker proxy upgrade payload.
            (
                UPGRADE_CTM_DEPLOYMENT_TRACKER,
                "ctm_deployment_tracker_proxy",
                "ctm_deployment_tracker_implementation_addr",
            ),
            // Verify chain asset handler proxy upgrade payload.
            (
                UPGRADE_CHAIN_ASSET_HANDLER,
                "chain_asset_handler_proxy",
                "chain_asset_handler_implementation_addr",
            ),
        ] {
            errors += verify_upgrade_call_args(
                &self.calls,
                index,
                proxy_name,
                implementation_name,
                verifiers,
                result,
            );
        }

        // Verify MessageRoot upgradeAndCall payload.
        errors += verify_message_root_upgrade_call_args(
            &self.calls,
            UPGRADE_MESSAGE_ROOT,
            verifiers,
            result,
        );

        // Per-CTM block: CTM proxy upgrade, setChainCreationParams,
        // setNewVersionUpgrade. Validated against each CTM's own
        // chain_upgrade_diamond_cut + contracts_config.
        for (i, ctm) in artifact.ctms.iter().enumerate() {
            let block = ctm_block_start(i);
            result.print_info(&format!(
                "-- CTM[{i}] = {} ----------------------",
                ctm.flavor.label()
            ));
            errors += verify_ctm_upgrade_call_args(
                &self.calls,
                block + PER_CTM_OFFSET_UPGRADE_CTM,
                ctm,
                verifiers,
                result,
            );
            errors += verify_set_chain_creation_params_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS,
                ctm,
                verifiers,
                result,
            )
            .await;
            errors += verify_set_new_version_upgrade_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE,
                ctm,
                verifiers,
                result,
            )
            .await?;
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }

    pub(crate) async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        l1_expected_chain_creation_facets: FacetCutSet,
        l1_expected_upgrade_facets: FacetCutSet,
        l1_expected_chain_upgrade_diamond_cut: &str,
        l1_bytecodes_supplier_addr: Address,
    ) -> anyhow::Result<(String, String)> {
        // Legacy single-CTM caller: assumes exactly one per-CTM block.
        let expected_len = STAGE1_PREFIX_LEN + STAGE1_PER_CTM_LEN;
        if self.calls.elems.len() != expected_len {
            result.report_error(&format!(
                "Legacy single-CTM stage1 shape mismatch: expected {} calls, got {}",
                expected_len,
                self.calls.elems.len()
            ));
        }
        result.print_info("== Gov stage 1 payloads ===");

        const SET_CHAIN_CREATION_PARAMS: usize =
            STAGE1_PREFIX_LEN + PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS;
        const SET_NEW_VERSION_UPGRADE: usize =
            STAGE1_PREFIX_LEN + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE;

        // Verify setNewVersionUpgrade.
        let calldata = &self
            .calls
            .elems
            .get(SET_NEW_VERSION_UPGRADE)
            .context("missing setNewVersionUpgrade call")?
            .data;
        let data = set_new_version_upgrade::setNewVersionUpgradeCall::abi_decode(calldata)
            .context("decoding setNewVersionUpgrade")?;

        if data.oldProtocolVersionDeadline != U256::MAX {
            result.report_error("Wrong old protocol version deadline for stage1 call");
        }

        if data.newProtocolVersion != Into::<U256>::into(get_expected_new_protocol_version()) {
            result.report_error("Wrong new protocol version for stage1 call");
        }
        if data.oldProtocolVersion != Into::<U256>::into(get_expected_old_protocol_version()) {
            result.report_error("Wrong old protocol version for stage1 call");
        }
        result.expect_address(verifiers, &data.verifier, "verifier");

        let diamond_cut = data.diamondCut;
        let expected_diamond_cut = l1_expected_chain_upgrade_diamond_cut
            .strip_prefix("0x")
            .unwrap_or(l1_expected_chain_upgrade_diamond_cut);
        let actual_diamond_cut = hex::encode(diamond_cut.abi_encode());
        if !actual_diamond_cut.eq_ignore_ascii_case(expected_diamond_cut) {
            result.report_error(&format!(
                "Invalid chain upgrade diamond cut. Expected: {}\n Received: {}",
                l1_expected_chain_upgrade_diamond_cut, actual_diamond_cut
            ));
        }

        result.expect_address(verifiers, &diamond_cut.initAddress, "default_upgrade");

        verity_facet_cuts(&diamond_cut.facetCuts, result, l1_expected_upgrade_facets).await;

        let upgrade =
            super::set_new_version_upgrade::upgradeCall::abi_decode(&diamond_cut.initCalldata)
                .context("decoding default upgrade calldata")?;

        upgrade
            ._proposedUpgrade
            .verify(verifiers, result, l1_bytecodes_supplier_addr, false)
            .await
            .context("proposed upgrade")?;

        // Verify setChainCreationParams.
        let decoded = setChainCreationParamsCall::abi_decode(
            &self
                .calls
                .elems
                .get(SET_CHAIN_CREATION_PARAMS)
                .context("missing setChainCreationParams call")?
                .data,
        )
        .context("decoding setChainCreationParams")?;
        decoded
            ._chainCreationParams
            .verify(verifiers, result, l1_expected_chain_creation_facets, false)
            .await?;

        let ChainCreationParams {
            diamondCut,
            forceDeploymentsData,
            ..
        } = decoded._chainCreationParams;

        Ok((
            hex::encode(diamondCut.abi_encode()),
            hex::encode(forceDeploymentsData),
        ))
    }
}

fn verify_upgrade_call_args(
    calls: &CallList,
    index: usize,
    proxy_name: &str,
    implementation_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing upgrade call at stage1 index {index}"));
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            errors += expect_named_address(result, verifiers, &decoded.proxy, proxy_name);
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.implementation,
                implementation_name,
            );
            if errors == 0 {
                result.report_ok(&format!(
                    "Upgrade payload for {proxy_name} uses {implementation_name}"
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode upgrade call at stage1 index {index}: {err}"
            ));
            1
        }
    }
}

fn verify_message_root_upgrade_call_args(
    calls: &CallList,
    index: usize,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing MessageRoot upgradeAndCall call");
        return 1;
    };

    match upgradeAndCallCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            errors += expect_named_address(result, verifiers, &decoded.proxy, "l1_message_root");
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.implementation,
                "message_root_implementation_addr",
            );

            match initializeL1V31UpgradeCall::abi_decode(&decoded.data) {
                Ok(_) => {
                    result.report_ok("MessageRoot upgrade payload calls initializeL1V31Upgrade")
                }
                Err(err) => {
                    result.report_error(&format!(
                        "MessageRoot upgradeAndCall payload is not initializeL1V31Upgrade(): {err}"
                    ));
                    errors += 1;
                }
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode MessageRoot upgradeAndCall: {err}"
            ));
            1
        }
    }
}

fn verify_ctm_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing ChainTypeManager upgrade call");
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            if let Some(expected_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_proxy"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.proxy,
                    expected_proxy,
                    &format!("{}.chain_type_manager_proxy", ctm.flavor.label()),
                );
            } else {
                errors += 1;
            }
            if let Some(expected_impl) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_implementation_addr"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.implementation,
                    expected_impl,
                    &format!(
                        "{}.chain_type_manager_implementation_addr",
                        ctm.flavor.label()
                    ),
                );
            } else {
                errors += 1;
            }
            if errors == 0 {
                result.report_ok(&format!(
                    "{} ChainTypeManager upgrade payload uses expected proxy and implementation",
                    ctm.flavor.label()
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode ChainTypeManager upgrade call: {err}"
            ));
            1
        }
    }
}

async fn verify_set_chain_creation_params_payload(
    calls: &CallList,
    index: usize,
    ctm: &crate::upgrade_verification::artifacts::CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing setChainCreationParams call");
        return 1;
    };

    let decoded = match setChainCreationParamsCall::abi_decode(&call.data) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!("Failed to decode setChainCreationParams: {err}"));
            return 1;
        }
    };
    let params = decoded._chainCreationParams;

    let mut errors = 0;
    if let Some(expected_genesis_upgrade) =
        required_ctm_address(ctm, &["state_transition", "genesis_upgrade_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &params.genesisUpgrade,
            expected_genesis_upgrade,
            &format!("{}.genesis_upgrade_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }
    if let Some(expected_diamond_init) =
        required_ctm_address(ctm, &["state_transition", "diamond_init_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &params.diamondCut.initAddress,
            expected_diamond_init,
            &format!("{}.diamond_init_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    let genesis_config = verifiers.genesis_config_for_ctm(ctm.flavor);
    if params.genesisBatchHash.to_string() != genesis_config.genesis_root {
        result.report_error(&format!(
            "Expected genesis batch hash to be {}, but got {}",
            genesis_config.genesis_root, params.genesisBatchHash
        ));
        errors += 1;
    }

    if let Some(genesis_rollup_leaf_index) = genesis_config.genesis_rollup_leaf_index {
        if params.genesisIndexRepeatedStorageChanges != genesis_rollup_leaf_index {
            result.report_error(&format!(
                "Expected genesis index repeated storage changes to be {}, but got {}",
                genesis_rollup_leaf_index, params.genesisIndexRepeatedStorageChanges
            ));
            errors += 1;
        }
    }

    if let Some(genesis_batch_commitment) = &genesis_config.genesis_batch_commitment {
        if params.genesisBatchCommitment.to_string() != *genesis_batch_commitment {
            result.report_error(&format!(
                "Expected genesis batch commitment to be {}, but got {}",
                genesis_batch_commitment, params.genesisBatchCommitment
            ));
            errors += 1;
        }
    }

    errors += expect_hex_equal(
        result,
        "chain creation diamond cut",
        &ctm.contracts_config.diamond_cut_data,
        &hex::encode(params.diamondCut.abi_encode()),
    );
    errors += expect_hex_equal(
        result,
        "force deployments data",
        &ctm.contracts_config.force_deployments_data,
        &hex::encode(&params.forceDeploymentsData),
    );

    // Decode forceDeploymentsData and verify each field independently so the
    // artifact hex is not merely trusted as a self-referential source of truth.
    result.print_info(&format!(
        "-- forceDeploymentsData field verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    match FixedForceDeploymentsData::abi_decode(&params.forceDeploymentsData) {
        Ok(fixed_data) => {
            if let Err(err) = fixed_data.verify(verifiers, result).await {
                result.report_error(&format!(
                    "forceDeploymentsData field verification failed: {err}"
                ));
                errors += 1;
            }
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode setChainCreationParams forceDeploymentsData: {err}"
            ));
            errors += 1;
        }
    }

    // Decode the chain-creation diamond cut's initCalldata and verify the three
    // bytecode hashes independently of the artifact hex.
    result.print_info(&format!(
        "-- InitializeDataNewChain field verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    match InitializeDataNewChain::abi_decode(&params.diamondCut.initCalldata) {
        Ok(init_data) => init_data.verify(verifiers, result),
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode InitializeDataNewChain from chain-creation initCalldata: {err}"
            ));
            errors += 1;
        }
    }

    errors
}

async fn verify_set_new_version_upgrade_payload(
    calls: &CallList,
    index: usize,
    ctm: &crate::upgrade_verification::artifacts::CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let calldata = &calls
        .elems
        .get(index)
        .context("missing setNewVersionUpgrade call")?
        .data;
    let data = set_new_version_upgrade::setNewVersionUpgradeCall::abi_decode(calldata)
        .context("decoding setNewVersionUpgrade")?;

    let mut errors = 0;
    let artifact_old_protocol_version = U256::from(ctm.contracts_config.old_protocol_version);
    let artifact_new_protocol_version = U256::from(ctm.contracts_config.new_protocol_version);

    if data.oldProtocolVersion != artifact_old_protocol_version {
        result.report_error(&format!(
            "setNewVersionUpgrade old protocol version mismatch: expected {} from TOML, got {}",
            artifact_old_protocol_version, data.oldProtocolVersion
        ));
        errors += 1;
    } else {
        result.report_ok(&format!(
            "{} setNewVersionUpgrade old protocol version matches TOML ({})",
            ctm.flavor.label(),
            protocol_label(artifact_old_protocol_version)
        ));
    }

    let decoded_old_protocol_version = ProtocolVersion::from(artifact_old_protocol_version);
    let expected_old_protocol_version: U256 =
        get_expected_old_protocol_version_for_ctm_flavor(ctm.flavor).into();
    if artifact_old_protocol_version != expected_old_protocol_version {
        result.report_error(&format!(
            "{} CTM old protocol version must be {}, got {}",
            ctm.flavor.label(),
            expected_old_protocol_version_label(ctm.flavor),
            decoded_old_protocol_version
        ));
        errors += 1;
    } else {
        result.report_ok(&format!(
            "{} CTM old protocol version is {}",
            ctm.flavor.label(),
            expected_old_protocol_version_label(ctm.flavor)
        ));
    }

    if let Some(ctm_addr) = required_ctm_address(
        ctm,
        &["state_transition", "chain_type_manager_proxy"],
        result,
    ) {
        match verifiers
            .network_verifier
            .try_get_ctm_protocol_version(ctm_addr)
            .await
        {
            Ok(onchain_old_protocol_version)
                if onchain_old_protocol_version == data.oldProtocolVersion =>
            {
                result.report_ok("setNewVersionUpgrade old protocol version matches on-chain CTM");
            }
            Ok(onchain_old_protocol_version) => {
                result.report_error(&format!(
                    "setNewVersionUpgrade old protocol version mismatch: on-chain CTM is {}, calldata uses {}",
                    onchain_old_protocol_version, data.oldProtocolVersion
                ));
                errors += 1;
            }
            Err(err) => result.report_warn(&format!(
                "Skipping on-chain CTM protocolVersion check; RPC unavailable or contract call failed: {err}"
            )),
        }
    }

    if data.oldProtocolVersionDeadline != U256::MAX {
        result.report_error("Wrong old protocol version deadline for stage1 call");
        errors += 1;
    }

    if data.newProtocolVersion != artifact_new_protocol_version {
        result.report_error(&format!(
            "setNewVersionUpgrade new protocol version mismatch: expected {} from TOML, got {}",
            artifact_new_protocol_version, data.newProtocolVersion
        ));
        errors += 1;
    }

    let decoded_new_protocol_version = ProtocolVersion::from(artifact_new_protocol_version);
    if decoded_new_protocol_version != get_expected_new_protocol_version() {
        result.report_error(&format!(
            "Invalid new protocol version in TOML. Expected {}, got {}",
            get_expected_new_protocol_version(),
            decoded_new_protocol_version
        ));
        errors += 1;
    }

    if let Some(expected_verifier) =
        required_ctm_address(ctm, &["state_transition", "verifier_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &data.verifier,
            expected_verifier,
            &format!("{}.verifier_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    let diamond_cut = data.diamondCut;
    errors += expect_hex_equal(
        result,
        "chain upgrade diamond cut",
        &ctm.chain_upgrade_diamond_cut,
        &hex::encode(diamond_cut.abi_encode()),
    );
    if let Some(expected_default_upgrade) =
        required_ctm_address(ctm, &["state_transition", "default_upgrade_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &diamond_cut.initAddress,
            expected_default_upgrade,
            &format!("{}.default_upgrade_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    errors += verify_v31_upgrade_facet_cuts(&diamond_cut.facetCuts, ctm, verifiers, result).await?;
    // Phase 5: when the artifact names a `bytecodes_supplier_addr` we also
    // verify that every L2 upgrade tx `factoryDeps` entry has been published
    // in `BytecodesSupplier` on the live L1 RPC. The legacy PUVT performed
    // this check unconditionally; the calldata-only verifier dropped it, and
    // we restore it here.
    let bytecodes_supplier_addr = required_ctm_address(
        ctm,
        &["state_transition", "bytecodes_supplier_addr"],
        result,
    );
    errors += verify_default_upgrade_payload(
        &diamond_cut.initCalldata,
        artifact_new_protocol_version,
        &ctm.contracts_config.force_deployments_data,
        verifiers,
        result,
        bytecodes_supplier_addr,
        ctm.flavor,
    )
    .await?;

    Ok(errors)
}

async fn verify_default_upgrade_payload(
    init_calldata: &[u8],
    expected_new_protocol_version: U256,
    expected_fixed_force_deployments_data: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bytecodes_supplier_addr: Option<Address>,
    ctm_flavor: CtmFlavor,
) -> anyhow::Result<usize> {
    let upgrade = set_new_version_upgrade::upgradeCall::abi_decode(init_calldata)
        .context("decoding DefaultUpgrade.upgrade calldata")?;
    upgrade
        ._proposedUpgrade
        .verify_v31_template(
            verifiers,
            result,
            expected_new_protocol_version,
            expected_fixed_force_deployments_data,
            bytecodes_supplier_addr,
            ctm_flavor,
        )
        .await
}

async fn verify_v31_upgrade_facet_cuts(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let initial_error_count = result.errors;
    let proposed_facet_cuts = proposed_upgrade_facet_cut_set(facet_cuts, result);

    match expected_v31_upgrade_facet_cuts(ctm, verifiers, result).await? {
        Some(ExpectedFacetCuts::Exact {
            facets: expected_facet_cuts,
            chain_id,
        }) if proposed_facet_cuts == expected_facet_cuts => {
            result.report_ok(&format!(
                "{} chain upgrade facet cuts match chain {} current diamond and new facets",
                ctm.flavor.label(),
                chain_id
            ));
        }
        Some(ExpectedFacetCuts::Exact {
            facets: expected_facet_cuts,
            chain_id,
        }) => {
            result.report_error(&format!(
                "Invalid {} chain upgrade facet cuts for representative chain {}. Expected: {:#?}\nReceived: {:#?}",
                ctm.flavor.label(),
                chain_id,
                expected_facet_cuts,
                proposed_facet_cuts
            ));
        }
        None if verifiers.representative_era_chain_id.is_none() => {
            result.report_warn(
                "Skipped exact chain upgrade facet-cut reconstruction; pass --era-chain-id to inspect a live chain diamond",
            );
        }
        None => {}
    }

    Ok((result.errors - initial_error_count) as usize)
}

fn proposed_upgrade_facet_cut_set(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    result: &mut VerificationResult,
) -> FacetCutSet {
    let mut used_add = false;
    let mut proposed_facet_cuts = FacetCutSet::new();
    for facet in facet_cuts {
        let action = match facet.action {
            set_new_version_upgrade::Action::Add => {
                used_add = true;
                facet_cut_set::Action::Add
            }
            set_new_version_upgrade::Action::Remove => {
                if used_add {
                    result.report_error(
                        "Remove action is unexpected after Add in upgrade diamond cut",
                    );
                }
                if facet.facet != Address::ZERO {
                    result.report_error(&format!(
                        "Remove action must use zero facet address, got {}",
                        facet.facet
                    ));
                }
                facet_cut_set::Action::Remove
            }
            set_new_version_upgrade::Action::Replace => {
                result.report_error("Replace action is unexpected in upgrade diamond cut");
                continue;
            }
            set_new_version_upgrade::Action::__Invalid => {
                result.report_error("Invalid action in upgrade diamond cut");
                continue;
            }
        };

        proposed_facet_cuts.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }
    proposed_facet_cuts
}

fn proposed_added_facet_cut_set(facet_cuts: &[set_new_version_upgrade::FacetCut]) -> FacetCutSet {
    let mut proposed_facet_cuts = FacetCutSet::new();
    for facet in facet_cuts {
        if !matches!(facet.action, set_new_version_upgrade::Action::Add) {
            continue;
        }
        proposed_facet_cuts.add_facet(FacetInfo {
            facet: facet.facet,
            action: facet_cut_set::Action::Add,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }
    proposed_facet_cuts
}

enum ExpectedFacetCuts {
    Exact { facets: FacetCutSet, chain_id: U256 },
}

struct RepresentativeChainDiamond {
    chain_id: U256,
    diamond: Address,
}

async fn expected_v31_upgrade_facet_cuts(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<Option<ExpectedFacetCuts>> {
    let added_facets = expected_v31_added_facets(ctm, verifiers, result).await?;
    let Some(representative) = find_representative_chain_diamond(ctm, verifiers, result).await?
    else {
        result.report_error(&format!(
            "Cannot reconstruct exact {} chain upgrade facet cuts: no registered chain on this CTM matches artifact old protocol {}",
            ctm.flavor.label(),
            protocol_label(U256::from(ctm.contracts_config.old_protocol_version))
        ));
        return Ok(None);
    };

    let current_facets = match GettersFacet::new(
        representative.diamond,
        verifiers.network_verifier.get_l1_provider(),
    )
    .facets()
    .call()
    .await
    {
        Ok(facets) => facets,
        Err(err) => {
            result.report_error(&format!(
                "Cannot fetch current diamond facets from {}: {err}",
                representative.diamond
            ));
            return Ok(None);
        }
    };

    let mut facets_to_remove = FacetCutSet::new();
    for facet in current_facets {
        facets_to_remove.add_facet(FacetInfo {
            facet: Address::ZERO,
            is_freezable: false,
            action: facet_cut_set::Action::Remove,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }

    Ok(Some(ExpectedFacetCuts::Exact {
        facets: facets_to_remove.merge(added_facets),
        chain_id: representative.chain_id,
    }))
}

async fn find_representative_chain_diamond(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<Option<RepresentativeChainDiamond>> {
    let Some(ctm_proxy) = required_ctm_address(
        ctm,
        &["state_transition", "chain_type_manager_proxy"],
        result,
    ) else {
        return Ok(None);
    };

    let expected_protocol = U256::from(ctm.contracts_config.old_protocol_version);

    if ctm.flavor == CtmFlavor::Era {
        if let Some(era_chain_id) = verifiers.representative_era_chain_id {
            let chain_id = U256::from(era_chain_id);
            if let Some(representative) = inspect_chain_for_facet_cut_reconstruction(
                chain_id,
                ctm_proxy,
                expected_protocol,
                verifiers,
            )
            .await?
            {
                return Ok(Some(representative));
            }
        }
    }

    let chain_ids = match verifiers
        .network_verifier
        .try_get_all_zk_chain_ids(verifiers.bridgehub_address)
        .await
    {
        Ok(ids) => ids,
        Err(err) => {
            result.report_warn(&format!(
                "Cannot scan registered chains for {} facet removal reconstruction: {err}",
                ctm.flavor.label()
            ));
            return Ok(None);
        }
    };

    for chain_id in chain_ids {
        if let Some(representative) = inspect_chain_for_facet_cut_reconstruction(
            chain_id,
            ctm_proxy,
            expected_protocol,
            verifiers,
        )
        .await?
        {
            return Ok(Some(representative));
        }
    }

    Ok(None)
}

async fn inspect_chain_for_facet_cut_reconstruction(
    chain_id: U256,
    expected_ctm: Address,
    expected_protocol: U256,
    verifiers: &Verifiers,
) -> anyhow::Result<Option<RepresentativeChainDiamond>> {
    let chain_ctm = match verifiers
        .network_verifier
        .try_get_chain_type_manager_from_bridgehub(verifiers.bridgehub_address, chain_id)
        .await
    {
        Ok(chain_ctm) => chain_ctm,
        Err(_) => return Ok(None),
    };
    if chain_ctm != expected_ctm {
        return Ok(None);
    }

    let diamond = match verifiers
        .network_verifier
        .try_get_chain_diamond_from_bridgehub(verifiers.bridgehub_address, chain_id)
        .await
    {
        Ok(diamond) if diamond != Address::ZERO => diamond,
        _ => return Ok(None),
    };

    let protocol = match verifiers
        .network_verifier
        .try_get_chain_protocol_version(diamond)
        .await
    {
        Ok(protocol) => protocol,
        Err(_) => return Ok(None),
    };
    if protocol != expected_protocol {
        return Ok(None);
    }

    Ok(Some(RepresentativeChainDiamond { chain_id, diamond }))
}

fn protocol_label(version: U256) -> String {
    format!("{} ({version})", ProtocolVersion::from(version))
}

async fn expected_v31_added_facets(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<FacetCutSet> {
    let mut facets_to_add = FacetCutSet::new();
    for (facet_name, is_freezable) in EXPECTED_V31_UPGRADE_FACETS {
        let Some(facet_address) =
            required_ctm_address(ctm, &["state_transition", facet_name], result)
        else {
            continue;
        };

        let bytecode = match verifiers
            .network_verifier
            .get_l1_provider()
            .get_code_at(facet_address)
            .await
        {
            Ok(bytecode) if !bytecode.is_empty() => bytecode,
            Ok(_) => {
                result.report_error(&format!(
                    "No bytecode at expected facet {} ({})",
                    facet_name, facet_address
                ));
                continue;
            }
            Err(err) => {
                result.report_error(&format!(
                    "Cannot fetch bytecode for expected facet {} ({}): {err}",
                    facet_name, facet_address
                ));
                continue;
            }
        };

        let selectors = facet_selectors_from_bytecode(&bytecode);
        if selectors.is_empty() {
            result.report_error(&format!(
                "Cannot derive selectors from expected facet {} ({})",
                facet_name, facet_address
            ));
            continue;
        }

        facets_to_add.add_facet(FacetInfo {
            facet: facet_address,
            action: facet_cut_set::Action::Add,
            is_freezable,
            selectors,
        });
    }

    Ok(facets_to_add)
}

const EXPECTED_V31_UPGRADE_FACETS: [(&str, bool); 6] = [
    ("admin_facet_addr", false),
    ("getters_facet_addr", false),
    ("mailbox_facet_addr", true),
    ("executor_facet_addr", true),
    ("migrator_facet_addr", false),
    ("committer_facet_addr", true),
];

fn facet_selectors_from_bytecode(bytecode: &[u8]) -> HashSet<[u8; 4]> {
    evmole::contract_info(evmole::ContractInfoArgs::new(bytecode).with_selectors())
        .functions
        .unwrap_or_default()
        .into_iter()
        .map(|function| function.selector)
        // Exclude getName(); this is included for tooling only and is not part of the diamond cut.
        .filter(|selector| selector != &[0x17, 0xd7, 0xde, 0x7c])
        .collect()
}

fn expect_named_address(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    address: &Address,
    expected_name: &str,
) -> usize {
    if result.expect_address(verifiers, address, expected_name) {
        0
    } else {
        1
    }
}

fn expect_address_equal(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    actual: &Address,
    expected: Address,
    expected_label: &str,
) -> usize {
    if *actual == expected {
        result.report_ok(&format!("{expected_label} address matches"));
        0
    } else {
        result.report_error(&format!(
            "Expected {} to be {}, but got {} ({})",
            expected_label,
            expected,
            actual,
            verifiers.address_verifier.name_or_unknown(actual)
        ));
        1
    }
}

fn expect_hex_equal(
    result: &mut VerificationResult,
    label: &str,
    expected: &str,
    actual_without_prefix: &str,
) -> usize {
    let expected_without_prefix = expected.strip_prefix("0x").unwrap_or(expected);
    if actual_without_prefix.eq_ignore_ascii_case(expected_without_prefix) {
        result.report_ok(&format!("{label} matches"));
        0
    } else {
        result.report_error(&format!(
            "{} mismatch. Expected: {}\nReceived: 0x{}",
            label, expected, actual_without_prefix
        ));
        1
    }
}

fn verify_call_by_name(
    calls: &CallList,
    index: usize,
    target_name: &str,
    method_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(expected_target) = verifiers
        .address_verifier
        .name_to_address
        .get(target_name)
        .copied()
    else {
        result.report_error(&format!("Expected call target {target_name} is not known"));
        return 1;
    };

    verify_call_by_address(
        calls,
        index,
        expected_target,
        target_name,
        method_name,
        verifiers,
        result,
    )
}

fn verify_call_by_address(
    calls: &CallList,
    index: usize,
    expected_target: Address,
    expected_label: &str,
    method_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!(
            "Expected call #{index} to {expected_label} with {method_name} not found"
        ));
        return 1;
    };

    let mut errors = 0;
    if call.target != expected_target {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but target is {}",
            expected_label,
            method_name,
            verifiers.address_verifier.name_or_unknown(&call.target)
        ));
        errors += 1;
    }
    if call.value != U256::ZERO {
        result.report_error(&format!(
            "Expected call #{index} to {} with {} to have zero value, but got {}",
            expected_label, method_name, call.value
        ));
        errors += 1;
    }
    if call.data.len() < 4 {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but call data is too short",
            expected_label, method_name
        ));
        return errors + 1;
    }

    let expected_selector = compute_selector(method_name);
    let actual_selector = hex::encode(&call.data[0..4]);
    if actual_selector != expected_selector {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but selector was {}",
            expected_label, method_name, actual_selector
        ));
        errors += 1;
    }

    if errors == 0 {
        result.report_ok(&format!("Called {expected_label} with {method_name}"));
    }
    errors
}

fn required_ctm_address(
    ctm: &CtmArtifact,
    path: &[&str],
    result: &mut VerificationResult,
) -> Option<Address> {
    let path_label = format!("ctms.{}.{}", ctm.flavor.label(), path.join("."));
    let mut current = &ctm.value;
    for segment in path {
        let Some(next) = current.get(*segment) else {
            result.report_error(&format!("{path_label} is required"));
            return None;
        };
        current = next;
    }

    let Some(raw) = current.as_str() else {
        result.report_error(&format!("{path_label} must be an address string"));
        return None;
    };

    match Address::from_str(raw) {
        Ok(address) => Some(address),
        Err(err) => {
            result.report_error(&format!("{path_label} is not a valid address: {err}"));
            None
        }
    }
}

impl ChainCreationParams {
    /// Verifies the chain creation parameters.
    pub async fn verify(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        expected_chain_creation_facets: FacetCutSet,
        is_gateway: bool,
    ) -> anyhow::Result<()> {
        result.print_info("== Chain creation params ==");
        let genesis_upgrade_name = verifiers
            .address_verifier
            .name_or_unknown(&self.genesisUpgrade);

        let name = if is_gateway {
            "gateway_genesis_upgrade_addr"
        } else {
            "genesis_upgrade_addr"
        };

        if genesis_upgrade_name != name {
            result.report_error(&format!(
                "Expected genesis upgrade address to be genesis_upgrade_addr, but got {}",
                genesis_upgrade_name
            ));
        }

        if self.genesisBatchHash.to_string() != verifiers.genesis_config.genesis_root {
            result.report_error(&format!(
                "Expected genesis batch hash to be {}, but got {}",
                verifiers.genesis_config.genesis_root, self.genesisBatchHash
            ));
        }

        if let Some(genesis_rollup_leaf_index) = verifiers.genesis_config.genesis_rollup_leaf_index
        {
            if self.genesisIndexRepeatedStorageChanges != genesis_rollup_leaf_index {
                result.report_error(&format!(
                    "Expected genesis index repeated storage changes to be {}, but got {}",
                    genesis_rollup_leaf_index, self.genesisIndexRepeatedStorageChanges
                ));
            }
        }

        if let Some(genesis_batch_commitment) = &verifiers.genesis_config.genesis_batch_commitment {
            if self.genesisBatchCommitment.to_string() != *genesis_batch_commitment {
                result.report_error(&format!(
                    "Expected genesis batch commitment to be {}, but got {}",
                    genesis_batch_commitment, self.genesisBatchCommitment
                ));
            }
        }

        verify_chain_creation_diamond_cut(
            verifiers,
            result,
            &self.diamondCut,
            expected_chain_creation_facets,
            is_gateway,
        )
        .await?;

        let fixed_force_deployments_data =
            FixedForceDeploymentsData::abi_decode(&self.forceDeploymentsData)
                .expect("Failed to decode FixedForceDeploymentsData");
        fixed_force_deployments_data
            .verify(verifiers, result)
            .await?;

        Ok(())
    }
}

/// Verifies the diamond cut used during chain creation.
pub async fn verify_chain_creation_diamond_cut(
    verifiers: &crate::upgrade_verification::verifiers::Verifiers,
    result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    diamond_cut: &DiamondCutData,
    expected_chain_creation_facets: FacetCutSet,
    is_gateway: bool,
) -> anyhow::Result<()> {
    let mut proposed_facet_cut = FacetCutSet::new();
    for facet in &diamond_cut.facetCuts {
        let action = match facet.action {
            Action::Add => facet_cut_set::Action::Add,
            Action::Remove => {
                result.report_error("Remove action is unexpected in diamond cut");
                continue;
            }
            Action::Replace => {
                result.report_error("Replace action is unexpected in diamond cut");
                continue;
            }
            Action::__Invalid => {
                result.report_error("Invalid action in diamond cut");
                continue;
            }
        };
        proposed_facet_cut.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }

    if expected_chain_creation_facets != proposed_facet_cut {
        result.report_error(&format!(
            "Invalid chain creation facet cut. Expected: {:#?}\nReceived: {:#?}",
            expected_chain_creation_facets, proposed_facet_cut
        ));
    }

    let name = if is_gateway {
        "gateway_diamond_init_addr"
    } else {
        "diamond_init"
    };
    result.expect_address(verifiers, &diamond_cut.initAddress, name);
    let initialize_data_new_chain = InitializeDataNewChain::abi_decode(&diamond_cut.initCalldata)
        .expect("Failed to decode InitializeDataNewChain");
    initialize_data_new_chain.verify(verifiers, result);

    Ok(())
}

pub async fn verity_facet_cuts(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    expected_upgrade_facets: FacetCutSet,
) {
    // We ensure two invariants here:
    // - Firstly we use `Remove` operations only. This is mainly for ensuring that
    // the upgrade will pass.
    // - Secondly, we ensure that the set of operations is identical.
    let mut used_add = false;
    let mut proposed_facet_cuts = FacetCutSet::new();
    facet_cuts.iter().for_each(|facet| {
        let action = match facet.action {
            set_new_version_upgrade::Action::Add => {
                used_add = true;
                facet_cut_set::Action::Add
            }
            set_new_version_upgrade::Action::Remove => {
                assert!(!used_add, "Unexpected `Remove` operation after `Add`");
                facet_cut_set::Action::Remove
            }
            set_new_version_upgrade::Action::Replace => panic!("Replace unexpected"),
            set_new_version_upgrade::Action::__Invalid => panic!("Invalid unexpected"),
        };

        proposed_facet_cuts.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    });

    if proposed_facet_cuts != expected_upgrade_facets {
        result.report_error(&format!(
            "Incorrect facet cuts. Expected {:#?}\nReceived: {:#?}",
            expected_upgrade_facets, proposed_facet_cuts
        ));
    }
}

impl GovernanceStage0Calls {
    /// Legacy single-CTM stage0 verifier retained for copied PUVT scaffolding.
    pub(crate) fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 0 calls ===");

        let list_of_calls = [
            // Pause migrations.
            ("chain_asset_handler_proxy", "pauseMigration()"),
            // Start the upgrade timer.
            ("upgrade_timer", "startTimer()"),
        ];
        self.calls.verify(&list_of_calls, verifiers, result)
    }

    /// Stage0 is executed before the main upgrade starts.
    ///
    /// Stage-0 shape:
    ///   `[ pauseMigration, startTimer (×N CTMs), <optional PUH-redeploy pair> ]`
    ///
    /// The trailing pair is only emitted on **PUH-governed envs**
    /// (`governance_kind = "puh"` in permanent-values — stage / mainnet today).
    /// `upgrade-prepare-all` appends it via `puh_guardians::deploy_puh_guardians`
    /// when bridgehub.owner() is a ProtocolUpgradeHandler proxy: first call
    /// upgrades the PUH implementation on its ProxyAdmin, second call rewires
    /// the new Guardians on the proxy itself. We detect PUH governance by
    /// reading `bridgehub.owner()` and probing its EIP-1967 admin slot — a
    /// non-zero admin means the owner is a TUPP-style proxy (= PUH on our
    /// envs), and we then expect the two extra calls.
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 0 calls ===");

        let mut errors = 0;
        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "pauseMigration()",
            verifiers,
            result,
        );

        for (ctm_index, ctm) in artifact.ctms.iter().enumerate() {
            let timer_label = format!("{}.upgrade_timer", ctm.flavor.label());
            if let Some(timer) = required_ctm_address(
                ctm,
                &["deployed_addresses", "l1_governance_upgrade_timer"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    1 + ctm_index,
                    timer,
                    &timer_label,
                    "startTimer()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }
        }

        // Probe for PUH-governed env.
        let bridgehub_owner = BridgehubOwnerView::new(
            verifiers.bridgehub_address,
            verifiers.network_verifier.get_l1_provider(),
        )
        .owner()
        .call()
        .await
        .context("read Bridgehub.owner() to detect PUH-governed env")?;
        let bridgehub_owner_admin = verifiers
            .network_verifier
            .get_proxy_admin(bridgehub_owner)
            .await;
        let puh_governed = bridgehub_owner_admin != Address::ZERO;

        let base_count = 1 + artifact.ctms.len();
        let expected_call_count = if puh_governed {
            base_count + 2
        } else {
            base_count
        };

        if puh_governed {
            let upgrade_idx = base_count;
            let update_guardians_idx = base_count + 1;
            // OZ v5 `TransparentUpgradeableProxyAdmin.upgradeAndCall` is the
            // selector used by `puh_guardians::encode_proxy_admin_upgrade` —
            // the v4 `upgrade(address,address)` selector reverts on the v5
            // admin. Data arg is empty (no follow-on call).
            errors += verify_call_by_address(
                &self.calls,
                upgrade_idx,
                bridgehub_owner_admin,
                "puh_proxy_admin",
                "upgradeAndCall(address,address,bytes)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(upgrade_idx) {
                match upgradeAndCallCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        if decoded.proxy != bridgehub_owner {
                            result.report_error(&format!(
                                "PUH upgrade call #{upgrade_idx} proxy arg {} does not match bridgehub.owner() {}",
                                decoded.proxy, bridgehub_owner
                            ));
                            errors += 1;
                        } else if !decoded.data.is_empty() {
                            result.report_error(&format!(
                                "PUH upgradeAndCall #{upgrade_idx} data arg should be empty for a bare impl swap, got {} bytes",
                                decoded.data.len()
                            ));
                            errors += 1;
                        } else {
                            result.report_ok(&format!(
                                "PUH upgradeAndCall(proxy=bridgehub.owner()) → new impl {}",
                                decoded.implementation
                            ));
                            errors += verify_address_has_code(
                                &decoded.implementation,
                                "PUH new implementation",
                                verifiers,
                                result,
                            )
                            .await;
                        }
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode upgradeAndCall(...) at call #{upgrade_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
            errors += verify_call_by_address(
                &self.calls,
                update_guardians_idx,
                bridgehub_owner,
                "puh_proxy",
                "updateGuardians(address)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(update_guardians_idx) {
                match updateGuardiansCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        result.report_ok(&format!(
                            "PUH updateGuardians(new={})",
                            decoded._newGuardians
                        ));
                        errors += verify_address_has_code(
                            &decoded._newGuardians,
                            "PUH new Guardians",
                            verifiers,
                            result,
                        )
                        .await;
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode updateGuardians(...) at call #{update_guardians_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
        }

        match self.calls.elems.len().cmp(&expected_call_count) {
            std::cmp::Ordering::Less => {
                result.report_error(&format!(
                    "Too few calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Greater => {
                result.report_error(&format!(
                    "Too many calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Equal => {}
        }
        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }
}

/// Lightweight cross-check that `addr` has runtime code on L1. PUVT's
/// `create2_known_bytecodes` only maps addresses for which the deploy's
/// init bytecode matched a known contract in `AllContractsHashes.json` —
/// PUH/Guardians come from the `zk-governance` repo whose artifacts aren't
/// in that file, so we can't bytecode-verify them. The minimum useful
/// invariant is "the address actually has code" — proves the new impl /
/// guardians address wasn't a typo / dangling address.
async fn verify_address_has_code(
    addr: &Address,
    label: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    use alloy::providers::Provider;
    let provider = verifiers.network_verifier.get_l1_provider();
    match provider.get_code_at(*addr).await {
        Ok(code) if !code.is_empty() => {
            result.report_ok(&format!(
                "{label} {addr} is deployed (code size {} bytes)",
                code.len()
            ));
            0
        }
        Ok(_) => {
            result.report_error(&format!(
                "{label} {addr} has no code — governance call references an undeployed address"
            ));
            1
        }
        Err(err) => {
            result.report_warn(&format!(
                "Skipping code-presence check for {label} {addr}: {err}"
            ));
            0
        }
    }
}

/// Verify the 15-call new-Gateway bring-up block that `write_merged_ecosystem_toml`
/// appends to stage 2 when the env has a `[new_gateway]` config. See the
/// docstring on `GovernanceStage2Calls::verify_artifact` for the call shape.
///
/// The verifier checks each call's (target, selector). Approve calls have
/// dynamic targets (the ZK base-token address resolved on-chain from
/// `NTV.tokenAddress(zkAssetId)`); we don't bother re-resolving here, but
/// we *do* assert every approve in the block targets the same address (any
/// inconsistency would mean the prepare emitted approvals against different
/// tokens — a serious shape break).
#[allow(clippy::too_many_arguments)]
async fn verify_gateway_bring_up_calls(
    calls: &CallList,
    base: usize,
    artifact: &EcosystemUpgradeArtifact,
    _new_gw: &crate::upgrade_verification::artifacts::NewGatewayArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    result.print_info("== Gov stage 2 new-Gateway bring-up ===");

    // (offset, target_name, method_signature)
    let direct = "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))";
    let two_bridges =
        "requestL2TransactionTwoBridges((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))";
    let expected: &[(usize, &str, &str)] = &[
        // L1AssetTracker.registerLegacyToken(zkAssetId) — prefix prepended
        // by `write_merged_ecosystem_toml` when `[new_gateway]` is present.
        (0, "asset_tracker_proxy", "registerLegacyToken(bytes32)"),
        // addChainTypeManager L1→L2 (priority tx) — approve + direct.
        (2, "bridgehub_proxy", direct),
        // setAssetDeploymentTracker on L1AssetRouter (L1-side, no approve).
        (
            3,
            "l1_asset_router_proxy",
            "setAssetDeploymentTracker(bytes32,address)",
        ),
        // registerCTMAssetOnL1 on L1CTMDeploymentTracker (L1-side).
        (
            4,
            "ctm_deployment_tracker_proxy",
            "registerCTMAssetOnL1(address)",
        ),
        // setAssetHandler for chain assetId — approve + two-bridges.
        (6, "bridgehub_proxy", two_bridges),
        // chain-asset-handler registration for GW CTM — approve + two-bridges.
        (8, "bridgehub_proxy", two_bridges),
        // acceptOwnership on RollupDAManager — approve + direct.
        (10, "bridgehub_proxy", direct),
        // acceptOwnership on ServerNotifier — approve + direct.
        (12, "bridgehub_proxy", direct),
        // setGatewaySettlementFee on GW_ASSET_TRACKER_ADDR — approve + direct.
        (14, "bridgehub_proxy", direct),
    ];

    let mut errors = 0;
    for (offset, target_name, method) in expected {
        errors += verify_call_by_name(calls, base + offset, target_name, method, verifiers, result);
    }

    // All approve calls in this block target the same ZK base-token address.
    // Their selector is `approve(address,uint256)` (0x095ea7b3) and the
    // spender is the L1AssetRouter — we check selector + cross-call target
    // consistency. The token's absolute address would need an extra RPC
    // round-trip (NTV.tokenAddress(zkAssetId)); cross-call consistency is
    // a sufficient shape check.
    let approve_selector = compute_selector("approve(address,uint256)");
    let approve_offsets = [1usize, 5, 7, 9, 11, 13];
    let mut approve_target: Option<Address> = None;
    for off in &approve_offsets {
        let idx = base + *off;
        let Some(call) = calls.elems.get(idx) else {
            result.report_error(&format!("Expected approve call #{idx} not found"));
            errors += 1;
            continue;
        };
        if call.data.len() < 4 || hex::encode(&call.data[0..4]) != approve_selector {
            result.report_error(&format!(
                "Call #{idx}: expected approve(address,uint256) selector 0x{approve_selector}, got 0x{}",
                hex::encode(&call.data[0..4.min(call.data.len())])
            ));
            errors += 1;
            continue;
        }
        match approve_target {
            None => approve_target = Some(call.target),
            Some(t) if t != call.target => {
                result.report_error(&format!(
                    "Approve call #{idx} target {} differs from earlier approve target {} — GW bring-up should approve a single base token",
                    call.target, t,
                ));
                errors += 1;
            }
            _ => {}
        }
    }
    if let Some(t) = approve_target {
        result.report_ok(&format!(
            "All 6 GW priority-tx approve calls target the same base token {t}"
        ));
    }

    // `chainId` is the first 32-byte field of every priority-tx struct
    // (both L2TransactionRequestDirect and L2TransactionRequestTwoBridgesOuter).
    // Decode + cross-check that every priority tx targets the SAME L2 chain.
    let priority_offsets = [2usize, 6, 8, 10, 12, 14];
    let mut priority_chain_id: Option<U256> = None;
    for off in &priority_offsets {
        let idx = base + *off;
        let Some(call) = calls.elems.get(idx) else {
            continue; // already counted as missing above
        };
        // ABI: 4-byte selector, then 32-byte offset to struct, then the
        // struct's first word = `chainId`.
        if call.data.len() < 4 + 32 + 32 {
            continue;
        }
        let chain_id_bytes: [u8; 32] = call.data[4 + 32..4 + 32 + 32]
            .try_into()
            .expect("32-byte chainId slice");
        let chain_id = U256::from_be_bytes(chain_id_bytes);
        match priority_chain_id {
            None => priority_chain_id = Some(chain_id),
            Some(prior) if prior != chain_id => {
                result.report_error(&format!(
                    "Priority tx #{idx} chainId {chain_id} differs from earlier priority tx chainId {prior} — GW bring-up should target a single L2 (the new gateway)",
                ));
                errors += 1;
            }
            _ => {}
        }
    }
    if let Some(cid) = priority_chain_id {
        result.report_ok(&format!(
            "All 6 GW priority txs target the same L2 chain id {cid}"
        ));
    }

    // Deep cross-check on the three `requestL2TransactionDirect` priority
    // txs whose targets/args we know how to derive from the artifact:
    //   - offset 2:  L2 Bridgehub ← addChainTypeManager(new_gw_ctm)
    //   - offset 10: GW RollupDAManager ← acceptOwnership()
    //   - offset 12: GW ServerNotifier ← acceptOwnership()
    // The remaining priority txs (offsets 6/8 two-bridges, 14 setSettlementFee)
    // are *not* deep-decoded yet — see follow-up note at the end of this fn.
    // L2 Bridgehub lives at the system-contract slot 0x10002 (see
    // `set_new_version_upgrade.rs::L2_BRIDGEHUB_ADDR`).
    let l2_bridgehub_addr = Address::from_str("0x0000000000000000000000000000000000010002").ok();
    let check_direct_inner = |idx_offset: usize,
                              expected_target_label: &str,
                              expected_target: Option<Address>,
                              expected_selector_sig: &str,
                              expected_arg: Option<Address>,
                              errors: &mut usize,
                              result: &mut VerificationResult| {
        let idx = base + idx_offset;
        let Some(call) = calls.elems.get(idx) else {
            return;
        };
        // Skip the 4-byte requestL2TransactionDirect selector + 32-byte
        // tuple offset.
        let payload = match call.data.len().checked_sub(4) {
            Some(n) if n > 0 => &call.data[4..],
            _ => return,
        };
        let Ok(req) = L2TransactionRequestDirect::abi_decode(payload) else {
            result.report_warn(&format!(
                "Could not decode L2TransactionRequestDirect for GW priority tx #{idx}; skipping inner cross-check"
            ));
            return;
        };
        if let Some(expected) = expected_target {
            if req.l2Contract != expected {
                result.report_error(&format!(
                    "GW priority tx #{idx} ({expected_target_label}) l2Contract mismatch: expected {expected}, got {}",
                    req.l2Contract
                ));
                *errors += 1;
            } else {
                result.report_ok(&format!(
                    "GW priority tx #{idx} ({expected_target_label}) l2Contract matches"
                ));
            }
        }
        if req.l2Calldata.len() < 4 {
            return;
        }
        let actual_sel = hex::encode(&req.l2Calldata[0..4]);
        let expected_sel = compute_selector(expected_selector_sig);
        if actual_sel != expected_sel {
            result.report_error(&format!(
                "GW priority tx #{idx} ({expected_target_label}) inner selector mismatch: expected {expected_selector_sig} (0x{expected_sel}), got 0x{actual_sel}"
            ));
            *errors += 1;
            return;
        }
        if let Some(expected_arg) = expected_arg {
            if req.l2Calldata.len() >= 4 + 32 {
                let arg_bytes: [u8; 32] = req.l2Calldata[4..36].try_into().unwrap();
                let actual_arg = Address::from_slice(&arg_bytes[12..]);
                if actual_arg != expected_arg {
                    result.report_error(&format!(
                        "GW priority tx #{idx} ({expected_target_label}) {expected_selector_sig} arg mismatch: expected {expected_arg}, got {actual_arg}"
                    ));
                    *errors += 1;
                } else {
                    result.report_ok(&format!(
                        "GW priority tx #{idx} ({expected_target_label}) {expected_selector_sig}({actual_arg}) matches"
                    ));
                }
            }
        }
    };

    let new_gw_ctm = _new_gw.gateway_chain_type_manager_addr;
    check_direct_inner(
        2,
        "addChainTypeManager",
        l2_bridgehub_addr,
        "addChainTypeManager(address)",
        Some(new_gw_ctm),
        &mut errors,
        result,
    );
    check_direct_inner(
        10,
        "acceptOwnership RollupDAManager",
        _new_gw.gateway_rollup_da_manager_addr,
        "acceptOwnership()",
        None,
        &mut errors,
        result,
    );
    check_direct_inner(
        12,
        "acceptOwnership ServerNotifier",
        _new_gw.gateway_server_notifier_addr,
        "acceptOwnership()",
        None,
        &mut errors,
        result,
    );

    // Touch the artifact so future extensions (e.g. cross-checking
    // setSettlementFee's fee value, decoding the two-bridges payloads) can
    // pull additional context from it without churn.
    let _ = artifact;
    errors
}

impl GovernanceStage2Calls {
    /// Legacy single-CTM stage2 verifier retained for copied PUVT scaffolding.
    pub(crate) fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        let list_of_calls = [
            // Unpause migrations.
            ("chain_asset_handler_proxy", "unpauseMigration()"),
            // Check that the protocol upgrade is present.
            ("upgrade_stage_validator", "checkProtocolUpgradePresence()"),
            // Check that migrations are unpaused.
            ("upgrade_stage_validator", "checkMigrationsUnpaused()"),
        ];
        self.calls.verify(&list_of_calls, verifiers, result)
    }

    /// Stage2 is executed after all chains have upgraded.
    ///
    /// Stage-2 shape (canonical):
    ///   `[ unpauseMigration, (checkProtocolUpgradePresence, checkMigrationsUnpaused) × N CTMs ]`
    ///
    /// When `[new_gateway]` is present in the merged ecosystem TOML,
    /// `write_merged_ecosystem_toml` prepends a `registerLegacyToken` prefix
    /// and appends the `GatewayVotePreparation` bring-up bundle. That extra
    /// section's expected shape is:
    ///   `[ registerLegacyToken,
    ///      approve + requestL2TransactionDirect      (addChainTypeManager on L2 BH),
    ///      setAssetDeploymentTracker,
    ///      registerCTMAssetOnL1,
    ///      approve + requestL2TransactionTwoBridges  (setAssetHandler for chain assetId),
    ///      approve + requestL2TransactionTwoBridges  (chain-asset-handler registration for GW CTM),
    ///      approve + requestL2TransactionDirect      (acceptOwnership RollupDAManager),
    ///      approve + requestL2TransactionDirect      (acceptOwnership ServerNotifier),
    ///      approve + requestL2TransactionDirect      (setGatewaySettlementFee on GW_ASSET_TRACKER_ADDR) ]`
    ///
    /// = 15 calls. `setSettlementLayerStatus` is *only* emitted when
    /// `ctm_representative_chain_id == gateway_chain_id` — that branch isn't
    /// configured for stage today, so this verifier does not expect it.
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        let mut errors = 0;
        let canonical_count = 1 + artifact.ctms.len() * 2;
        let gw_count = if artifact.new_gateway.is_some() {
            15
        } else {
            0
        };
        let expected_call_count = canonical_count + gw_count;

        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "unpauseMigration()",
            verifiers,
            result,
        );

        for (ctm_index, ctm) in artifact.ctms.iter().enumerate() {
            let validator_label = format!("{}.upgrade_stage_validator", ctm.flavor.label());
            let Some(validator) = required_ctm_address(
                ctm,
                &["deployed_addresses", "upgrade_stage_validator"],
                result,
            ) else {
                errors += 2;
                continue;
            };

            let block = 1 + ctm_index * 2;
            errors += verify_call_by_address(
                &self.calls,
                block,
                validator,
                &validator_label,
                "checkProtocolUpgradePresence()",
                verifiers,
                result,
            );
            errors += verify_call_by_address(
                &self.calls,
                block + 1,
                validator,
                &validator_label,
                "checkMigrationsUnpaused()",
                verifiers,
                result,
            );
        }

        if let Some(new_gw) = artifact.new_gateway.as_ref() {
            errors += verify_gateway_bring_up_calls(
                &self.calls,
                canonical_count,
                artifact,
                new_gw,
                verifiers,
                result,
            )
            .await;
        }

        match self.calls.elems.len().cmp(&expected_call_count) {
            std::cmp::Ordering::Less => {
                result.report_error(&format!(
                    "Too few calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Greater => {
                result.report_error(&format!(
                    "Too many calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Equal => {}
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }
}
