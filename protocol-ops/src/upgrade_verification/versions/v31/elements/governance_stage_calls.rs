use super::{
    call_list::CallList, fixed_force_deployment::FixedForceDeploymentsData,
    initialize_data_new_chain::InitializeDataNewChain, protocol_version::ProtocolVersion,
    set_new_version_upgrade,
};
use crate::upgrade_verification::{
    artifacts::EcosystemUpgradeArtifact,
    verifiers::{VerificationResult, Verifiers},
};

use super::super::{
    get_expected_new_protocol_version, get_expected_old_protocol_version,
    utils::facet_cut_set::{self, FacetCutSet, FacetInfo},
};
use alloy::{
    hex,
    primitives::{Address, FixedBytes, U256},
    sol,
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;

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
}

pub(crate) fn verify_governance_stage_calls(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let stage0 = GovernanceStage0Calls {
        calls: CallList::parse(&artifact.governance_calls.stage0_calls),
    };
    stage0.verify(verifiers, result)?;

    let stage1 = GovernanceStage1Calls {
        calls: CallList::parse(&artifact.governance_calls.stage1_calls),
    };
    stage1.verify_artifact(artifact, verifiers, result)?;

    let stage2 = GovernanceStage2Calls {
        calls: CallList::parse(&artifact.governance_calls.stage2_calls),
    };
    stage2.verify(verifiers, result)?;

    Ok(())
}

impl GovernanceStage1Calls {
    pub(crate) fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        self.verify_call_shape(verifiers, result)?;
        self.verify_artifact_payloads(artifact, verifiers, result)
    }

    fn verify_call_shape(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 calls ===");

        const ACCEPT_ASSET_TRACKER_OWNERSHIP: usize = 7;
        const SET_ASSET_TRACKER: usize = 8;

        let list_of_calls = [
            // Upgrade Bridgehub proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 nullifier proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 asset router proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade native token vault proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade message root proxy and initialize v31 state.
            (
                "transparent_proxy_admin",
                "upgradeAndCall(address,address,bytes)",
            ),
            // Upgrade CTM deployment tracker proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade chain asset handler proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Accept AssetTracker ownership.
            ("asset_tracker_proxy", "acceptOwnership()"),
            // Wire AssetTracker into NativeTokenVault.
            ("native_token_vault", "setAssetTracker(address)"),
            // Check that the upgrade timer deadline has passed.
            ("upgrade_timer", "checkDeadline()"),
            // Check that migrations are paused.
            ("upgrade_stage_validator", "checkMigrationsPaused()"),
            // Upgrade CTM proxy.
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // Set chain creation params on the upgraded CTM.
            (
                "chain_type_manager_proxy",
                "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))",
            ),
            // Register the new protocol version upgrade on the upgraded CTM.
            (
                "chain_type_manager_proxy",
                "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256,address)",
            ),
        ];
        self.calls.verify(&list_of_calls, verifiers, result)?;

        // The accepted AssetTracker proxy must be the one wired into NativeTokenVault.
        let mut errors = 0;
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

    fn verify_artifact_payloads(
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
        const UPGRADE_CTM: usize = 11;
        const SET_CHAIN_CREATION_PARAMS: usize = 12;
        const SET_NEW_VERSION_UPGRADE: usize = 13;

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
        // Verify CTM proxy upgrade payload.
        errors += verify_ctm_upgrade_call_args(&self.calls, UPGRADE_CTM, verifiers, result);
        // Verify CTM chain creation params payload from the ecosystem TOML.
        errors += verify_set_chain_creation_params_payload(
            &self.calls,
            SET_CHAIN_CREATION_PARAMS,
            artifact,
            verifiers,
            result,
        );
        // Verify CTM new version upgrade payload from the ecosystem TOML.
        errors += verify_set_new_version_upgrade_payload(
            &self.calls,
            SET_NEW_VERSION_UPGRADE,
            artifact,
            verifiers,
            result,
        )?;

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
        self.verify_call_shape(verifiers, result)?;
        result.print_info("== Gov stage 1 payloads ===");

        const SET_CHAIN_CREATION_PARAMS: usize = 12;
        const SET_NEW_VERSION_UPGRADE: usize = 13;

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
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.proxy,
                "chain_type_manager_proxy",
            );
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.implementation,
                "chain_type_manager_implementation_addr",
            );
            if errors == 0 {
                result.report_ok(
                    "ChainTypeManager upgrade payload uses expected proxy and implementation",
                );
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

fn verify_set_chain_creation_params_payload(
    calls: &CallList,
    index: usize,
    artifact: &EcosystemUpgradeArtifact,
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
    errors += expect_named_address(
        result,
        verifiers,
        &params.genesisUpgrade,
        "genesis_upgrade_addr",
    );
    errors += expect_named_address(
        result,
        verifiers,
        &params.diamondCut.initAddress,
        "diamond_init",
    );

    if params.genesisBatchHash.to_string() != verifiers.genesis_config.genesis_root {
        result.report_error(&format!(
            "Expected genesis batch hash to be {}, but got {}",
            verifiers.genesis_config.genesis_root, params.genesisBatchHash
        ));
        errors += 1;
    }

    if let Some(genesis_rollup_leaf_index) = verifiers.genesis_config.genesis_rollup_leaf_index {
        if params.genesisIndexRepeatedStorageChanges != genesis_rollup_leaf_index {
            result.report_error(&format!(
                "Expected genesis index repeated storage changes to be {}, but got {}",
                genesis_rollup_leaf_index, params.genesisIndexRepeatedStorageChanges
            ));
            errors += 1;
        }
    }

    if let Some(genesis_batch_commitment) = &verifiers.genesis_config.genesis_batch_commitment {
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
        &artifact.contracts_config.diamond_cut_data,
        &hex::encode(params.diamondCut.abi_encode()),
    );
    errors += expect_hex_equal(
        result,
        "force deployments data",
        &artifact.contracts_config.force_deployments_data,
        &hex::encode(&params.forceDeploymentsData),
    );

    errors
}

fn verify_set_new_version_upgrade_payload(
    calls: &CallList,
    index: usize,
    artifact: &EcosystemUpgradeArtifact,
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
    let artifact_old_protocol_version = U256::from(artifact.contracts_config.old_protocol_version);
    let artifact_new_protocol_version = U256::from(artifact.contracts_config.new_protocol_version);

    if data.oldProtocolVersion != artifact_old_protocol_version {
        result.report_error(&format!(
            "setNewVersionUpgrade old protocol version mismatch: expected {} from TOML, got {}",
            artifact_old_protocol_version, data.oldProtocolVersion
        ));
        errors += 1;
    }

    let decoded_old_protocol_version = ProtocolVersion::from(artifact_old_protocol_version);
    if !is_allowed_v31_old_protocol_version(decoded_old_protocol_version) {
        result.report_error(&format!(
            "Unsupported v31 source protocol version in TOML: {}",
            decoded_old_protocol_version
        ));
        errors += 1;
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

    errors += expect_named_address(result, verifiers, &data.verifier, "verifier");

    let diamond_cut = data.diamondCut;
    errors += expect_hex_equal(
        result,
        "chain upgrade diamond cut",
        &artifact.chain_upgrade_diamond_cut,
        &hex::encode(diamond_cut.abi_encode()),
    );
    errors += expect_named_address(
        result,
        verifiers,
        &diamond_cut.initAddress,
        "default_upgrade",
    );
    errors += verify_default_upgrade_payload(
        &diamond_cut.initCalldata,
        artifact_new_protocol_version,
        result,
    )?;

    Ok(errors)
}

fn verify_default_upgrade_payload(
    init_calldata: &[u8],
    expected_new_protocol_version: U256,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let upgrade = set_new_version_upgrade::upgradeCall::abi_decode(init_calldata)
        .context("decoding DefaultUpgrade.upgrade calldata")?;
    let proposed_upgrade = upgrade._proposedUpgrade;
    let mut errors = 0;

    if proposed_upgrade.newProtocolVersion != expected_new_protocol_version {
        result.report_error(&format!(
            "ProposedUpgrade new protocol version mismatch: expected {}, got {}",
            expected_new_protocol_version, proposed_upgrade.newProtocolVersion
        ));
        errors += 1;
    }

    if proposed_upgrade.verifier != Address::ZERO {
        result.report_error(&format!(
            "ProposedUpgrade verifier must be zero, got {}",
            proposed_upgrade.verifier
        ));
        errors += 1;
    }

    let zero_hash = FixedBytes::<32>::ZERO;
    if proposed_upgrade.verifierParams.recursionNodeLevelVkHash != zero_hash
        || proposed_upgrade.verifierParams.recursionLeafLevelVkHash != zero_hash
        || proposed_upgrade.verifierParams.recursionCircuitsSetVksHash != zero_hash
    {
        result.report_error("ProposedUpgrade verifier params must be empty");
        errors += 1;
    }

    if !proposed_upgrade.l1ContractsUpgradeCalldata.is_empty() {
        result.report_error("ProposedUpgrade l1ContractsUpgradeCalldata must be empty for v31");
        errors += 1;
    }

    if !proposed_upgrade.postUpgradeCalldata.is_empty() {
        result.report_error("ProposedUpgrade postUpgradeCalldata must be empty for v31");
        errors += 1;
    }

    if errors == 0 {
        result.report_ok("DefaultUpgrade payload has expected v31 static fields");
    }
    Ok(errors)
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

fn is_allowed_v31_old_protocol_version(version: ProtocolVersion) -> bool {
    version.major == 0 && matches!(version.minor, 29 | 30)
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
    initialize_data_new_chain
        .verify(verifiers, result, is_gateway)
        .await?;

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
    /// Stage0 is executed before the main upgrade starts.
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
}

impl GovernanceStage2Calls {
    /// Stage2 is executed after all chains have upgraded.
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
}
