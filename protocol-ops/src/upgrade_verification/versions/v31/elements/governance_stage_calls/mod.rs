//! Governance ceremony call-list verification (Stages 0/1/2).
//!
//! This module owns the two public entrypoints called from `v31::verify`
//! ([`verify_governance_stage_calls`] and [`verify_per_chain_protocol_versions`]),
//! the shared `sol!` types referenced by external decoders, and the three
//! per-stage wrapper structs.
//!
//! Per-stage logic lives in submodules:
//! - [`stage0`] — Stage 0 orchestrator + PUH-immutables verification.
//! - [`stage1`] — Stage 1 orchestrator + the 6 per-call payload verifiers.
//! - [`stage2`] — Stage 2 orchestrator + new-Gateway bring-up walker.
//!
//! Cross-cutting machinery:
//! - [`helpers`] — call-shape primitives (`verify_call_by_*`), address-book
//!   primitives (`expect_*`, `required_*_address`), and small utilities like
//!   `protocol_label` and `verify_address_has_code`.
//! - [`facets`] — independent diamond-cut facet-set reconstruction (used by
//!   both Stage 1's `setNewVersionUpgrade` decoder and the chain-creation
//!   payload decoder).

use std::collections::HashMap;

use alloy::{
    primitives::{Address, U256},
    sol,
};

use crate::upgrade_verification::{
    artifacts::EcosystemUpgradeArtifact,
    verifiers::{VerificationResult, Verifiers},
};

use super::{call_list::CallList, super::expected_old_protocol_version_label};
use super::super::get_expected_old_protocol_version_for_ctm_flavor;

mod facets;
mod helpers;
mod stage0;
mod stage1;
mod stage2;

use helpers::{protocol_label, required_ctm_address};

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

    #[sol(rpc)]
    contract ProtocolUpgradeHandler {
        function L2_PROTOCOL_GOVERNOR() external view returns (address);
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function ERA_CHAIN_TYPE_MANAGER() external view returns (address);
        function ZKSYNC_OS_CHAIN_TYPE_MANAGER() external view returns (address);
        function BRIDGE_HUB() external view returns (address);
        function L1_NULLIFIER() external view returns (address);
        function L1_ASSET_ROUTER() external view returns (address);
        function L1_NATIVE_TOKEN_VAULT() external view returns (address);
        function CHAIN_ASSET_HANDLER() external view returns (address);
        function ERA_CHAIN_ID() external view returns (uint256);
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
