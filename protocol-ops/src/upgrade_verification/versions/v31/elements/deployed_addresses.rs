use anyhow::Result;

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
    versions::v31::MAX_NUMBER_OF_ZK_CHAINS,
    constants::{EIP1967_PROXY_ADMIN_SLOT, L2_INTEROP_CENTER_ADDR},
};

use alloy::{
    hex::FromHex,
    primitives::{Address, FixedBytes, U256},
    providers::Provider,
    sol,
    sol_types::{SolCall, SolConstructor},
};
use serde::Deserialize;
use std::str::FromStr;

const MAINNET_CHAIN_ID: u64 = 1;
// TODO: remove this name here
const CREATE2_FACTORY_CONTRACT_NAME: &str = "Create2Factory";

sol! {
    #[sol(rpc)]
    contract L1AssetRouter {
        /// @dev Address of native token vault.
        address public nativeTokenVault;

        /// @dev Address of legacy bridge.
        address public legacyBridge;

        address public owner;
    }
    #[sol(rpc)]
    contract V31ChainTypeManagerView {
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
    }
    /// @notice Faсet structure compatible with the EIP-2535 diamond loupe
    /// @param addr The address of the facet contract
    /// @param selectors The NON-sorted array with selectors associated with facet
    struct Facet {
        address addr;
        bytes4[] selectors;
    }
    contract V31AdminFacet {
        constructor(uint256 _l1ChainId, address _rollupDAManager);
    }
    contract V31ExecutorFacet {
        constructor(uint256 _l1ChainId);
    }
    contract V31CommitterFacet {
        constructor(uint256 _l1ChainId);
    }
    contract V31MailboxFacet {
        constructor(
            uint256 _eraChainId,
            uint256 _l1ChainId,
            address _chainAssetHandler,
            address _eip7702Checker,
            bool _isTestnet
        );
    }
    contract V31L1Bridgehub {
        constructor(address _owner, uint256 _maxNumberOfZKChains);
    }
    contract V31L1NativeTokenVault {
        constructor(address _wethToken, address _assetRouter, address _l1Nullifier);
    }
    contract V31L1AssetRouter {
        constructor(
            address _l1WethToken,
            address _bridgehub,
            address _l1Nullifier,
            uint256 _eraChainId,
            address _eraDiamondProxy
        );
    }
    contract V31L1Nullifier {
        constructor(
            address _bridgehub,
            address _messageRoot,
            uint256 _eraChainId,
            address _eraDiamondProxy
        );
    }
    contract V31L1MessageRoot {
        constructor(address _bridgehub, uint256 _eraGatewayChainId, address _chainAssetHandler);
    }
    contract V31L1AssetTracker {
        constructor(address _bridgehub, address _nativeTokenVault, address _messageRoot);
    }
    contract V31L1ChainAssetHandler {
        constructor(address _owner, address _bridgehub);
    }
    contract V31ChainTypeManager {
        constructor(
            address _bridgehub,
            address _interopCenter,
            address _l1BytecodesSupplier,
            address _permissionlessValidator
        );
    }
    contract V31PermissionlessValidator {
        function initialize();
    }
    contract V31BytecodesSupplier {
        function initialize();
    }
    contract V31CTMDeploymentTracker {
        constructor(address _bridgehub, address _l1AssetRouter);
    }
    contract V31DualVerifier {
        constructor(address _fflonkVerifier, address _plonkVerifier);
    }
    contract V31ZKsyncOSDualVerifier {
        constructor(address _fflonkVerifier, address _plonkVerifier, address _initialOwner);
    }
    contract V31MigratorFacet {
        constructor(uint256 _l1ChainId, bool _isTestnet);
    }
    contract V31GovernanceUpgradeTimer {
        constructor(
            uint256 _initialDelay,
            uint256 _maxAdditionalDelay,
            address _timerGovernance,
            address _initialOwner
        );
    }
    contract V31UpgradeStageValidator {
        constructor(address chainTypeManager, uint256 newProtocolVersion);
    }
    contract V31ChainRegistrationSender {
        constructor(address _bridgehub);
    }
    contract V31ValidatorTimelock {
        constructor(address _bridgehubAddr);
    }
}

#[derive(Debug, Deserialize)]
pub struct DeployedAddresses {
    pub(crate) native_token_vault_implementation_addr: Address,

    pub(crate) validator_timelock_addr: Address,
    pub(crate) l1_bytecodes_supplier_addr: Address,
    pub(crate) l1_transitionary_owner: Address,
    pub(crate) l1_rollup_da_manager: Address,
    pub(crate) rollup_l1_da_validator_addr: Address,
    #[allow(dead_code)]
    pub(crate) validium_l1_da_validator_addr: Address,
    pub(crate) l1_governance_upgrade_timer: Address,
    pub(crate) bridges: Bridges,
    pub(crate) bridgehub: Bridgehub,
    pub(crate) state_transition: StateTransition,
    pub(crate) upgrade_stage_validator: Address,
}

#[derive(Debug, Deserialize)]
pub struct Bridges {
    pub l1_asset_router_implementation_addr: Address,
    pub l1_nullifier_implementation_addr: Address,
}

#[derive(Debug, Deserialize)]
pub struct Bridgehub {
    bridgehub_implementation_addr: Address,
    message_root_proxy_addr: Address,
    message_root_implementation_addr: Address,
    // Note, that while the original file may contain impl addresses,
    // we do not include or verify those here since the correctness of the
    // actual implementation behind the proxies above is already checked.
}

#[derive(Debug, Deserialize)]
pub struct StateTransition {
    pub admin_facet_addr: Address,
    pub default_upgrade_addr: Address,
    pub diamond_init_addr: Address,
    pub executor_facet_addr: Address,
    pub genesis_upgrade_addr: Address,
    pub getters_facet_addr: Address,
    pub mailbox_facet_addr: Address,
    pub migrator_facet_addr: Address,
    pub committer_facet_addr: Address,
    pub state_transition_implementation_addr: Address,
    pub verifier_addr: Address,
    pub verifier_fflonk_addr: Address,
    pub verifier_plonk_addr: Address,
}

sol! {
    #[sol(rpc)]
    contract OwnableLike {
        function owner() external view returns (address);
    }
}

/// Proxies whose EIP-1967 admin slot must match `transparent_proxy_admin`.
/// These are the proxies that the v31 governance stage 1 calls upgrade.
const PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN: &[&str] = &[
    "bridgehub_proxy",
    "l1_nullifier_proxy",
    "l1_asset_router_proxy",
    "native_token_vault",
    "message_root_proxy",
    "ctm_deployment_tracker_proxy",
    "chain_asset_handler_proxy",
    "chain_type_manager_proxy",
    "asset_tracker_proxy",
];

/// Phase 5 RPC state checks (see `puvt-what-to-do.md`).
///
/// This is intentionally the *non-overlapping* slice of legacy PUVT's
/// post-deploy work — it covers checks that aren't subsumed by Phase 6
/// (deployment provenance):
/// - The L1 RPC chain id (sanity).
/// - Runtime bytecode at the configured Create2Factory address.
/// - Runtime bytecode at the ecosystem `transparent_proxy_admin` address.
/// - EIP-1967 proxy-admin slot for every v31 stage-1 proxy → must equal the
///   ecosystem `transparent_proxy_admin`.
/// - Pre-upgrade AssetRouter → NTV wiring when the getter exists on the live
///   proxy.
///
/// Per-implementation deployed-bytecode and constructor-arg checks live in
/// the legacy `DeployedAddresses::verify` path: they use init bytecode +
/// constructor args (via `expect_create2_params`), which handles Solidity
/// `immutable` substitution correctly. The flat-table runtime-hash check
/// previously here was strictly weaker and produced misleading errors for
/// every contract with immutables; Phase 6 supersedes it.
///
/// Bytecode-supplier `publishingBlock` checks for the L2 upgrade tx
/// `factoryDeps` are restored separately inside
/// `set_new_version_upgrade::verify_factory_deps` so they sit alongside the
/// rest of the L2 upgrade tx checks.
pub(crate) async fn verify_v31_artifact_state(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    create2_factory: Address,
    result: &mut VerificationResult,
) -> Result<()> {
    result.print_info("== RPC state checks ==");

    verify_l1_chain_id(verifiers, result).await;
    result
        .expect_deployed_bytecode(verifiers, &create2_factory, CREATE2_FACTORY_CONTRACT_NAME)
        .await;
    verify_v31_proxy_admins(verifiers, result).await;
    verify_v31_core_wiring(verifiers, result).await;
    verify_v31_ctm_permissionless_validator(artifact, verifiers, result).await;

    Ok(())
}

/// Deployment provenance.
///
/// For every named v31 implementation that the prepare scripts deploy via
/// CREATE2 (or `Create2AndTransfer`), assert that the executed-bundle log
/// contains a deployment whose init bytecode + abi-encoded constructor
/// args match what we'd expect for that contract. This is the
/// immutables-aware check: it verifies the contract was *produced* from
/// the right inputs, regardless of how immutables get baked into the
/// runtime bytecode.
///
/// The per-CTM TUPPs (`BytecodesSupplier` and `PermissionlessValidator`)
/// are verified with `expect_create2_params_proxy_with_bytecode`, using the
/// live implementation slot and the executed-bundle CREATE2 provenance.
///
/// Larger structural follow-up: unify `EcosystemUpgradeArtifact` and the
/// legacy `UpgradeOutput` into a single v31 TOML reader. The current
/// commit keeps both side-by-side; Phase 6 reuses only the create2
/// machinery from `NetworkVerifier` (which does not depend on
/// `UpgradeOutput`) so the unification can land independently.
pub(crate) async fn verify_v31_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    era_chain_id: u64,
    legacy_gateway_chain_id: u64,
    result: &mut VerificationResult,
) -> Result<()> {
    result.print_info("== Deployment provenance ==");

    let provider = verifiers.network_verifier.get_l1_provider();
    let l1_chain_id = verifiers
        .network_verifier
        .try_get_l1_chain_id()
        .await
        .unwrap_or_else(|err| panic!("Failed to fetch L1 chain id for provenance: {err}"));

    // Convenience lookups against the artifact-derived address verifier.
    // Each address used as a constructor input has to come from somewhere;
    // we tolerate missing entries because not every operator scenario
    // populates every named address.
    let lookup = |name: &str| {
        verifiers
            .address_verifier
            .name_to_address
            .get(name)
            .copied()
    };

    let is_testnet = artifact.contracts_config.is_testnet;

    for ctm in &artifact.ctms {
        verify_ctm_flavored_provenance(artifact, ctm, verifiers, l1_chain_id, result);
    }

    // The remaining contracts pull constructor args from the live
    // Bridgehub: weth, asset router, nullifier, era diamond proxy, etc.
    // The legacy `NetworkVerifier::get_bridgehub_info` is geared toward the
    // legacy (UpgradeOutput) flow and assumes a populated era chain id; in
    // the v31 artifact flow we read only the fields Phase 6 actually uses.
    let bridgehub_addr = verifiers.bridgehub_address;
    let bridgehub =
        super::super::utils::network_verifier::Bridgehub::new(bridgehub_addr, provider.clone());
    let asset_router_proxy = bridgehub.assetRouter().call().await.unwrap_or_else(|err| {
        panic!("Failed to call Bridgehub.assetRouter() for provenance: {err}")
    });
    let l1_asset_router = super::super::utils::network_verifier::L1AssetRouter::new(
        asset_router_proxy,
        provider.clone(),
    );
    let weth = l1_asset_router
        .L1_WETH_TOKEN()
        .call()
        .await
        .unwrap_or_else(|err| panic!("Failed to call L1AssetRouter.L1_WETH_TOKEN(): {err}"));
    let nullifier = l1_asset_router
        .L1_NULLIFIER()
        .call()
        .await
        .unwrap_or_else(|err| panic!("Failed to call L1AssetRouter.L1_NULLIFIER(): {err}"));
    let ntv_proxy = l1_asset_router
        .nativeTokenVault()
        .call()
        .await
        .unwrap_or_else(|err| panic!("Failed to call L1AssetRouter.nativeTokenVault(): {err}"));

    // L1NativeTokenVault impl(weth, assetRouter, nullifier).
    if let Some(ntv_impl) = lookup("native_token_vault_implementation_addr") {
        result.expect_create2_params(
            verifiers,
            &ntv_impl,
            V31L1NativeTokenVault::constructorCall::new((weth, asset_router_proxy, nullifier))
                .abi_encode(),
            "l1-contracts/L1NativeTokenVault",
        );
    }

    // CTMDeploymentTracker impl(bridgehub, l1AssetRouter).
    if let Some(ctmdt_impl) = lookup("ctm_deployment_tracker_implementation_addr") {
        result.expect_create2_params(
            verifiers,
            &ctmdt_impl,
            V31CTMDeploymentTracker::constructorCall::new((bridgehub_addr, asset_router_proxy))
                .abi_encode(),
            "l1-contracts/CTMDeploymentTracker",
        );
    }

    // L1AssetTracker impl(bridgehub, ntv, messageRoot).
    if let (Some(tracker_impl), Some(message_root_proxy)) = (
        lookup("l1_asset_tracker_implementation_addr"),
        lookup("message_root_proxy"),
    ) {
        result.expect_create2_params(
            verifiers,
            &tracker_impl,
            V31L1AssetTracker::constructorCall::new((
                bridgehub_addr,
                ntv_proxy,
                message_root_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1AssetTracker",
        );
    }

    // The era_chain_id-dependent constructors (L1AssetRouter / L1Nullifier)
    // require both the chain id and the chain's diamond proxy. The env provides
    // era_chain_id; the diamond proxy must resolve from Bridgehub.
    let era_diamond_proxy = verifiers
        .network_verifier
        .try_get_chain_diamond_from_bridgehub(bridgehub_addr, U256::from(era_chain_id))
        .await
        .unwrap_or_else(|err| {
            panic!("Failed to call Bridgehub.getZKChain({era_chain_id}) for provenance: {err}")
        });
    if era_diamond_proxy == Address::ZERO {
        panic!("Bridgehub.getZKChain({era_chain_id}) returned address(0) for provenance");
    }

    // L1AssetRouter impl(weth, bridgehub, nullifier, eraChainId, eraDiamondProxy).
    if let Some(asset_router_impl) = lookup("l1_asset_router_implementation_addr") {
        result.expect_create2_params(
            verifiers,
            &asset_router_impl,
            V31L1AssetRouter::constructorCall::new((
                weth,
                bridgehub_addr,
                nullifier,
                U256::from(era_chain_id),
                era_diamond_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1AssetRouter",
        );
    }

    // L1Nullifier impl(bridgehub, messageRoot, eraChainId, eraDiamondProxy).
    if let (Some(nullifier_impl), Some(message_root_proxy)) = (
        lookup("l1_nullifier_implementation_addr"),
        lookup("message_root_proxy"),
    ) {
        result.expect_create2_params(
            verifiers,
            &nullifier_impl,
            V31L1Nullifier::constructorCall::new((
                bridgehub_addr,
                message_root_proxy,
                U256::from(era_chain_id),
                era_diamond_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1Nullifier",
        );
    }

    // CommitterFacet(uint256 _l1ChainId).
    if let Some(committer) = lookup("committer_facet_addr") {
        result.expect_create2_params(
            verifiers,
            &committer,
            V31CommitterFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/CommitterFacet",
        );
    }

    // L1Bridgehub impl(_owner, _maxNumberOfZKChains). Owner is governance,
    // readable from `bridgehub.owner()`; max chains is the well-known v31
    // constant 100. Use file-match when the constructor-arg encoding drifts
    // between deploy script and contract source.
    if let Some(bridgehub_impl) = lookup("bridgehub_implementation_addr") {
        match bridgehub.owner().call().await {
            Ok(governance) => result.expect_create2_params(
                verifiers,
                &bridgehub_impl,
                V31L1Bridgehub::constructorCall::new((
                    governance,
                    U256::from(MAX_NUMBER_OF_ZK_CHAINS),
                ))
                .abi_encode(),
                "l1-contracts/L1Bridgehub",
            ),
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping owner-dependent provenance checks; bridgehub.owner() failed: {err}"
                ));
            }
        }
    }

    // The remaining v31 contracts. Constructor args come from a mix of
    // RPC reads (governance owner, l1ChainId), the artifact's address
    // map (chainAssetHandler, bytecodesSupplier, eip7702Checker),
    // the artifact's `[verifier_inputs]`
    // section (initialDelay, isTestnet), well-known constants
    // (`L2_INTEROP_CENTER_ADDR`, the GovernanceUpgradeTimer 2-week
    // window, MAX_NUMBER_OF_CHAINS = 100), and the prepare-time
    // governance owner (= `bridgehub.owner()` = the protocol upgrade
    // handler).
    let chain_asset_handler_proxy = lookup("chain_asset_handler_proxy");
    let eip7702_checker = lookup("eip7702_checker_addr");
    let governance = match bridgehub.owner().call().await {
        Ok(owner) => Some(owner),
        Err(err) => {
            result.report_warn(&format!(
                "Skipping owner-dependent provenance checks; bridgehub.owner() failed: {err}"
            ));
            None
        }
    };

    // MailboxFacet(eraChainId, l1ChainId, chainAssetHandler, eip7702Checker, isTestnet).
    if let (Some(mailbox), Some(chain_asset_handler), Some(eip7702)) = (
        lookup("mailbox_facet_addr"),
        chain_asset_handler_proxy,
        eip7702_checker,
    ) {
        result.expect_create2_params(
            verifiers,
            &mailbox,
            V31MailboxFacet::constructorCall::new((
                U256::from(era_chain_id),
                U256::from(l1_chain_id),
                chain_asset_handler,
                eip7702,
                is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MailboxFacet",
        );
    }

    // MigratorFacet(_l1ChainId, _isTestnet).
    if let Some(migrator) = lookup("migrator_facet_addr") {
        result.expect_create2_params(
            verifiers,
            &migrator,
            V31MigratorFacet::constructorCall::new((U256::from(l1_chain_id), is_testnet))
                .abi_encode(),
            "l1-contracts/MigratorFacet",
        );
    }

    // L1ChainAssetHandler(_owner=governance, _bridgehub).
    if let (Some(chain_asset_handler_impl), Some(governance)) = (
        lookup("chain_asset_handler_implementation_addr"),
        governance,
    ) {
        result.expect_create2_params(
            verifiers,
            &chain_asset_handler_impl,
            V31L1ChainAssetHandler::constructorCall::new((governance, bridgehub_addr)).abi_encode(),
            "l1-contracts/L1ChainAssetHandler",
        );
    }

    // L1MessageRoot(_bridgehub, _eraGatewayChainId, _chainAssetHandler).
    //
    // Stage Sepolia deploys the `L1MessageRootStageSepolia` variant (which
    // skips chain 270's still-on-GW-123 settlement check during
    // `_v31InitializeInner`) — its constructor signature is identical, but
    // the bytecode hash differs. Pick whichever file the CREATE2 deploy was
    // identified as, matching the same pattern the DualVerifier branch uses
    // for the testnet variant.
    if let (Some(message_root_impl), Some(chain_asset_handler)) = (
        lookup("message_root_implementation_addr"),
        chain_asset_handler_proxy,
    ) {
        let resolved_file = verifiers
            .network_verifier
            .create2_known_bytecodes
            .get(&message_root_impl)
            .cloned();
        let expected_file = match resolved_file.as_deref() {
            Some("l1-contracts/L1MessageRootStageSepolia") => {
                "l1-contracts/L1MessageRootStageSepolia"
            }
            _ => "l1-contracts/L1MessageRoot",
        };
        result.expect_create2_params(
            verifiers,
            &message_root_impl,
            V31L1MessageRoot::constructorCall::new((
                bridgehub_addr,
                U256::from(legacy_gateway_chain_id),
                chain_asset_handler,
            ))
            .abi_encode(),
            expected_file,
        );
    }

    // GovernanceUpgradeTimer(initialDelay, maxAdditionalDelay = 2 weeks,
    // timerGovernance = governance, initialOwner = governance).
    if let (Some(timer), Some(governance), initial_delay) = (
        lookup("l1_governance_upgrade_timer"),
        governance,
        artifact
            .contracts_config
            .governance_upgrade_timer_initial_delay,
    ) {
        const TWO_WEEKS_SECONDS: u64 = 2 * 7 * 24 * 60 * 60;
        result.expect_create2_params(
            verifiers,
            &timer,
            V31GovernanceUpgradeTimer::constructorCall::new((
                U256::from(initial_delay),
                U256::from(TWO_WEEKS_SECONDS),
                governance,
                governance,
            ))
            .abi_encode(),
            "l1-contracts/GovernanceUpgradeTimer",
        );
    }

    // UpgradeStageValidator(chainTypeManager, newProtocolVersion).
    if let Some(stage_validator) = lookup("upgrade_stage_validator") {
        if let Some(ctm_proxy) = lookup("chain_type_manager_proxy") {
            result.expect_create2_params(
                verifiers,
                &stage_validator,
                V31UpgradeStageValidator::constructorCall::new((
                    ctm_proxy,
                    U256::from(artifact.contracts_config.new_protocol_version),
                ))
                .abi_encode(),
                "l1-contracts/UpgradeStageValidator",
            );
        }
    }

    verify_per_ctm_v31_provenance(artifact, verifiers, result, bridgehub_addr).await?;

    // EIP7702Checker is part of the da-contracts package (not
    // l1-contracts) — `AllContractsHashes.json` records it as
    // `da-contracts/EIP7702Checker`.
    if let Some(eip7702) = eip7702_checker {
        result.expect_create2_params(
            verifiers,
            &eip7702,
            Vec::<u8>::new(),
            "da-contracts/EIP7702Checker",
        );
    }

    // ChainRegistrationSender(bridgehub). Deployed once by `CoreUpgrade_v31`
    // and surfaced as `[core.upgrade_addresses.bridgehub]
    // chain_registration_sender_implementation_addr`.
    if let Some(crs) = lookup("chain_registration_sender_implementation_addr") {
        result.expect_create2_params(
            verifiers,
            &crs,
            V31ChainRegistrationSender::constructorCall::new((bridgehub_addr,)).abi_encode(),
            "l1-contracts/ChainRegistrationSender",
        );
    }

    Ok(())
}

async fn verify_per_ctm_v31_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bridgehub_addr: Address,
) -> Result<()> {
    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        result.print_info(&format!("-- CTM deployment provenance: {label} --"));

        let Some(ctm_impl) = required_ctm_address(
            ctm,
            &["state_transition", "chain_type_manager_implementation_addr"],
            result,
        ) else {
            continue;
        };
        let Some(bytecodes_supplier) = required_ctm_address(
            ctm,
            &["state_transition", "bytecodes_supplier_addr"],
            result,
        ) else {
            continue;
        };
        let Some(permissionless_validator) = required_ctm_address(
            ctm,
            &["state_transition", "permissionless_validator_addr"],
            result,
        ) else {
            continue;
        };

        let ctm_file = match ctm.flavor {
            CtmFlavor::Era => "l1-contracts/EraChainTypeManager",
            CtmFlavor::ZksyncOs => "l1-contracts/ZKsyncOSChainTypeManager",
        };
        result.expect_create2_params(
            verifiers,
            &ctm_impl,
            V31ChainTypeManager::constructorCall::new((
                bridgehub_addr,
                L2_INTEROP_CENTER_ADDR,
                bytecodes_supplier,
                permissionless_validator,
            ))
            .abi_encode(),
            ctm_file,
        );

        let Some(transparent_proxy_admin) = required_ctm_address(
            ctm,
            &["deployed_addresses", "transparent_proxy_admin"],
            result,
        ) else {
            continue;
        };

        if bytecodes_supplier == Address::ZERO {
            result.report_warn(&format!(
                "Skipping {label} BytecodesSupplier provenance check; bytecodes_supplier_addr is address(0) in artifact"
            ));
        } else {
            result
                .expect_create2_params_proxy_with_bytecode(
                    verifiers,
                    &bytecodes_supplier,
                    V31BytecodesSupplier::initializeCall::new(()).abi_encode(),
                    transparent_proxy_admin,
                    Vec::<u8>::new(),
                    "l1-contracts/BytecodesSupplier",
                )
                .await;
        }

        if permissionless_validator == Address::ZERO {
            result.report_warn(&format!(
                "Skipping {label} PermissionlessValidator provenance check; permissionless_validator_addr is address(0) in artifact"
            ));
            continue;
        }
        result
            .expect_create2_params_proxy_with_bytecode(
                verifiers,
                &permissionless_validator,
                V31PermissionlessValidator::initializeCall::new(()).abi_encode(),
                transparent_proxy_admin,
                Vec::<u8>::new(),
                "l1-contracts/PermissionlessValidator",
            )
            .await;

        // ServerNotifier impl (no ctor args). One deployed per CTM by
        // `CTMUpgrade_v31`; surfaced as
        // `[ctms.<flavor>.state_transition] server_notifier_implementation_addr`.
        if let Some(server_notifier_impl) = required_ctm_address(
            ctm,
            &["state_transition", "server_notifier_implementation_addr"],
            result,
        ) {
            result.expect_create2_params(
                verifiers,
                &server_notifier_impl,
                Vec::<u8>::new(),
                "l1-contracts/ServerNotifier",
            );
        }

        // ValidatorTimelock impl (ctor: bridgehub). Deployed once per CTM by
        // `CTMUpgrade_v31`; the stage 1 governance call swaps this address
        // behind the per-CTM ValidatorTimelock proxy.
        if let Some(validator_timelock_impl) = required_ctm_address(
            ctm,
            &["state_transition", "validator_timelock_implementation_addr"],
            result,
        ) {
            result.expect_create2_params(
                verifiers,
                &validator_timelock_impl,
                V31ValidatorTimelock::constructorCall::new((bridgehub_addr,)).abi_encode(),
                "l1-contracts/ValidatorTimelock",
            );
        }
    }

    Ok(())
}

async fn verify_l1_chain_id(verifiers: &Verifiers, result: &mut VerificationResult) {
    match verifiers.network_verifier.try_get_l1_chain_id().await {
        Ok(chain_id) => result.report_ok(&format!("L1 RPC chain id: {chain_id}")),
        Err(err) => result.report_error(&format!("Failed to fetch L1 RPC chain id: {err}")),
    }
}

async fn verify_v31_proxy_admins(verifiers: &Verifiers, result: &mut VerificationResult) {
    let Some(expected_admin) = verifiers
        .address_verifier
        .name_to_address
        .get("transparent_proxy_admin")
    else {
        result.report_warn(
            "Skipping proxy-admin checks: transparent_proxy_admin not present in artifact",
        );
        return;
    };

    result
        .expect_deployed_bytecode(verifiers, expected_admin, "TransparentProxyAdmin")
        .await;

    let admin_slot = match FixedBytes::<32>::from_hex(EIP1967_PROXY_ADMIN_SLOT) {
        Ok(slot) => slot,
        Err(err) => {
            result.report_error(&format!("Invalid EIP-1967 admin slot literal: {err}"));
            return;
        }
    };

    let provider = verifiers.network_verifier.get_l1_provider();
    for proxy_name in PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN {
        let Some(proxy_addr) = verifiers.address_verifier.name_to_address.get(*proxy_name) else {
            result.report_warn(&format!(
                "Skipping proxy-admin check for {proxy_name}: address not present in artifact"
            ));
            continue;
        };
        let raw = match provider
            .get_storage_at(*proxy_addr, U256::from_be_bytes(admin_slot.0))
            .await
        {
            Ok(value) => value.to_be_bytes::<32>(),
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping proxy-admin check for {proxy_name}; eth_getStorageAt failed: {err}"
                ));
                continue;
            }
        };
        let actual_admin = Address::from_slice(&raw[12..]);
        if actual_admin == *expected_admin {
            result.report_ok(&format!(
                "Proxy admin for {proxy_name} matches transparent_proxy_admin"
            ));
        } else {
            result.report_error(&format!(
                "Proxy admin mismatch for {proxy_name}: expected {expected_admin}, got {actual_admin}"
            ));
        }
    }
}

async fn verify_v31_core_wiring(verifiers: &Verifiers, result: &mut VerificationResult) {
    let provider = verifiers.network_verifier.get_l1_provider();

    if let (Some(asset_router_proxy), Some(expected_ntv)) = (
        verifiers
            .address_verifier
            .name_to_address
            .get("l1_asset_router_proxy"),
        verifiers
            .address_verifier
            .name_to_address
            .get("native_token_vault"),
    ) {
        let asset_router = L1AssetRouter::new(*asset_router_proxy, provider.clone());
        match asset_router.nativeTokenVault().call().await {
            Ok(actual) if actual == *expected_ntv => {
                result.report_ok("L1AssetRouter.nativeTokenVault() points at native_token_vault")
            }
            Ok(actual) => result.report_error(&format!(
                "L1AssetRouter.nativeTokenVault() mismatch: expected {expected_ntv}, got {actual}"
            )),
            Err(err) => result.report_warn(&format!(
                "Skipping L1AssetRouter.nativeTokenVault() check; call failed: {err}"
            )),
        }
    }

    if let Some(expected_tracker) = verifiers
        .address_verifier
        .name_to_address
        .get("asset_tracker_proxy")
    {
        // Stage 1 accepts the AssetTracker ownership transfer; record the
        // current owner for context (ownership end-state validation requires
        // governance address knowledge added later in Phase 6).
        let tracker = OwnableLike::new(*expected_tracker, provider.clone());
        match tracker.owner().call().await {
            Ok(owner) => result.report_ok(&format!("AssetTracker owner: {owner}")),
            Err(err) => result.report_warn(&format!(
                "Skipping AssetTracker.owner() check; call failed: {err}"
            )),
        }
    }
}

async fn verify_v31_ctm_permissionless_validator(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) {
    let provider = verifiers.network_verifier.get_l1_provider();
    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let Some(ctm_impl) = required_ctm_address(
            ctm,
            &["state_transition", "chain_type_manager_implementation_addr"],
            result,
        ) else {
            continue;
        };
        let Some(expected_permissionless_validator) = required_ctm_address(
            ctm,
            &["state_transition", "permissionless_validator_addr"],
            result,
        ) else {
            continue;
        };

        if expected_permissionless_validator == Address::ZERO {
            result.report_error(&format!(
                "{label}.permissionless_validator_addr is address(0); v31 CTM implementations must be constructed with a PermissionlessValidator proxy"
            ));
            continue;
        }

        let ctm_view = V31ChainTypeManagerView::new(ctm_impl, provider.clone());
        match ctm_view.PERMISSIONLESS_VALIDATOR().call().await {
            Ok(actual) if actual == expected_permissionless_validator => result.report_ok(&format!(
                "{label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR() matches permissionless_validator_addr"
            )),
            Ok(actual) => result.report_error(&format!(
                "{label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR() mismatch: expected {expected_permissionless_validator}, got {actual}"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR(): {err}"
            )),
        }
    }
}

/// Per-CTM, per-flavor provenance for the contracts that ship one copy per
/// CTM (verifiers, DiamondInit, default_upgrade, genesis_upgrade, getters/
/// executor/admin facets). The v31 upgrade deploys these once for Era and
/// once for ZKsyncOS, so verification iterates per CTM and uses each CTM's
/// own `flavor`.
///
/// All addresses come from the CTM's own `[ctms.<flavor>]` section via
/// `required_ctm_address`. Optional addresses are silently skipped (some
/// older artifacts don't populate every field).
fn verify_ctm_flavored_provenance(
    artifact: &EcosystemUpgradeArtifact,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    l1_chain_id: u64,
    result: &mut VerificationResult,
) {
    let label = ctm.flavor.label();
    let is_zksync_os = matches!(ctm.flavor, CtmFlavor::ZksyncOs);

    // Per-flavor verifier file names. `AllContractsHashes.json` ships
    // per-flavor verifiers since v30, so we match each CTM's deploys
    // against the matching set.
    let (verifier_plonk_file, verifier_fflonk_file, dual_verifier_file, testnet_verifier_file) =
        match ctm.flavor {
            CtmFlavor::Era => (
                "l1-contracts/EraVerifierPlonk",
                "l1-contracts/EraVerifierFflonk",
                "l1-contracts/EraDualVerifier",
                "l1-contracts/EraTestnetVerifier",
            ),
            CtmFlavor::ZksyncOs => (
                "l1-contracts/ZKsyncOSVerifierPlonk",
                "l1-contracts/ZKsyncOSVerifierFflonk",
                "l1-contracts/ZKsyncOSDualVerifier",
                "l1-contracts/ZKsyncOSTestnetVerifier",
            ),
        };
    // Per-flavor SettlementLayerV31Upgrade variant. `default_upgrade_addr`
    // holds the new settlement-layer upgrade contract for the CTM.
    let default_upgrade_file = match ctm.flavor {
        CtmFlavor::Era => "l1-contracts/EraSettlementLayerV31Upgrade",
        CtmFlavor::ZksyncOs => "l1-contracts/ZKsyncOSSettlementLayerV31Upgrade",
    };

    let try_get = |path: &[&str]| -> Option<Address> {
        // Look up an optional field without reporting an error for missing.
        let mut current = &ctm.value;
        for segment in path {
            current = current.get(*segment)?;
        }
        let raw = current.as_str()?;
        Address::from_str(raw).ok()
    };

    // Constants with no constructor args.
    for (path, expected_file) in [
        (
            &["deployed_addresses", "l1_genesis_upgrade"][..],
            "l1-contracts/L1GenesisUpgrade",
        ),
        (
            &["state_transition", "genesis_upgrade_addr"],
            "l1-contracts/L1GenesisUpgrade",
        ),
        (
            &["state_transition", "getters_facet_addr"],
            "l1-contracts/GettersFacet",
        ),
        (
            &["state_transition", "default_upgrade_addr"],
            default_upgrade_file,
        ),
        (
            &["state_transition", "verifier_plonk_addr"],
            verifier_plonk_file,
        ),
        (
            &["state_transition", "verifier_fflonk_addr"],
            verifier_fflonk_file,
        ),
    ] {
        if let Some(addr) = try_get(path) {
            result.expect_create2_params(verifiers, &addr, Vec::<u8>::new(), expected_file);
        }
    }

    // DiamondInit(bool _isZKsyncOS) — encoded as a single 32-byte word.
    if let Some(diamond_init) = try_get(&["state_transition", "diamond_init_addr"]) {
        let mut encoded = vec![0u8; 32];
        if is_zksync_os {
            encoded[31] = 1;
        }
        result.expect_create2_params(
            verifiers,
            &diamond_init,
            encoded,
            "l1-contracts/DiamondInit",
        );
    }

    // ExecutorFacet(l1ChainId) — file is shared across flavors, but the
    // address is per-CTM (different CREATE2 init+args between CTMs only when
    // the deploy salt differs; both end up at the same logical contract
    // file).
    if let Some(executor) = try_get(&["state_transition", "executor_facet_addr"]) {
        result.expect_create2_params(
            verifiers,
            &executor,
            V31ExecutorFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/ExecutorFacet",
        );
    }

    // AdminFacet(l1ChainId, rollupDAManager) — rollupDAManager is per-CTM.
    let rollup_da_manager = try_get(&["deployed_addresses", "rollup_da_manager"])
        .or_else(|| try_get(&["state_transition", "rollup_da_manager"]))
        .or_else(|| try_get(&["rollup_da_manager"]));
    if let (Some(admin), Some(rollup_da_manager)) = (
        try_get(&["state_transition", "admin_facet_addr"]),
        rollup_da_manager,
    ) {
        result.expect_create2_params(
            verifiers,
            &admin,
            V31AdminFacet::constructorCall::new((U256::from(l1_chain_id), rollup_da_manager))
                .abi_encode(),
            "l1-contracts/AdminFacet",
        );
    }

    // DualVerifier(fflonk, plonk) / *TestnetVerifier.
    // Stage / testnet environments deploy the `*TestnetVerifier` flavor
    // instead of `*DualVerifier`; pick whichever the CREATE2 deploy was
    // actually identified as.
    //
    // ZKsyncOS verifiers take a third `_initialOwner` constructor arg
    // (the deployer EOA — `DeployCTMUtils.verifierOwner = getBroadcasterAddress()`)
    // and `DeployCTML1OrGateway.verifierCreationArgs` extends the encoding
    // accordingly. We don't have a canonical "expected owner" in the
    // artifact, but the deployed args are recoverable from
    // `create2_constructor_params`. Read them, extract the actual owner
    // (with format sanity checks), and reuse it as the expected arg —
    // effectively asserting `(fflonk, plonk)` match the artifact while
    // accepting whatever `_initialOwner` the broadcaster supplied.
    if let (Some(verifier), Some(fflonk), Some(plonk)) = (
        try_get(&["state_transition", "verifier_addr"]),
        try_get(&["state_transition", "verifier_fflonk_addr"]),
        try_get(&["state_transition", "verifier_plonk_addr"]),
    ) {
        let resolved_file = verifiers
            .network_verifier
            .create2_known_bytecodes
            .get(&verifier)
            .cloned();
        let expected_file = match resolved_file.as_deref() {
            Some(file) if file == testnet_verifier_file => testnet_verifier_file,
            _ => dual_verifier_file,
        };
        let encoded = if is_zksync_os {
            let initial_owner = verifiers
                .network_verifier
                .create2_constructor_params
                .get(&verifier)
                .and_then(|params| {
                    (params.len() == 96).then(|| Address::from_slice(&params[76..96]))
                })
                .unwrap_or(Address::ZERO);
            V31ZKsyncOSDualVerifier::constructorCall::new((fflonk, plonk, initial_owner))
                .abi_encode()
        } else {
            V31DualVerifier::constructorCall::new((fflonk, plonk)).abi_encode()
        };
        result.expect_create2_params(verifiers, &verifier, encoded, expected_file);
    }

    let _ = (artifact, label); // hooks for future per-CTM checks
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
