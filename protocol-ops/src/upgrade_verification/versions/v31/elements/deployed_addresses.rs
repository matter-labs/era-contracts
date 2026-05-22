use anyhow::{Context, Result};

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor, EcosystemUpgradeArtifact},
    constants::{EIP1967_PROXY_ADMIN_SLOT, L2_INTEROP_CENTER_ADDR},
    verifiers::{VerificationResult, Verifiers},
    versions::v31::{
        utils::network_verifier::{
            Bridgehub as BridgehubContract, ChainTypeManager, L1AssetRouter, Ownable,
        },
        MAX_NUMBER_OF_ZK_CHAINS,
    },
};

use alloy::{
    hex::FromHex,
    primitives::{Address, FixedBytes, U256},
    providers::Provider,
    sol_types::{SolCall, SolConstructor},
};
use serde::Deserialize;
use std::str::FromStr;

const GOVERNANCE_TIMER_MAX_ADDITIONAL_DELAY_SECONDS: u64 = 14 * 24 * 60 * 60;
// TODO: remove this name here
const CREATE2_FACTORY_CONTRACT_NAME: &str = "Create2Factory";

/// Expected constructor signatures for every contract deployed by
/// `CoreUpgrade_v31` (i.e. `verify_core_provenance`).
///
/// These declarations exist only to drive `abi_encode` for the expected
/// constructor-args byte slice; they are NOT used as RPC clients. The
/// signatures must match the corresponding Solidity contract under
/// `l1-contracts/contracts/core` / `l1-contracts/contracts/bridge`.
mod core_signatures {
    alloy::sol! {
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
            function initialize(address _owner);
        }
        contract V31L1ChainAssetHandler {
            constructor(address _owner, address _bridgehub);
        }
        contract V31CTMDeploymentTracker {
            constructor(address _bridgehub, address _l1AssetRouter);
        }
        contract V31ChainRegistrationSender {
            constructor(address _bridgehub);
        }
    }
}

/// Expected constructor signatures for every contract deployed by
/// `CTMUpgrade_v31` (i.e. `verify_ctm_provenance` and
/// `verify_ctm_base_provenance`).
///
/// `V31ChainTypeManager._interopCenter` is intentionally the L2 built-in
/// `INTEROP_CENTER` address — the contract stores it in an L1-side
/// `immutable` but uses it only when constructing L2-aliased messages
/// (see `ChainTypeManagerBase.sol`). Pass `L2_INTEROP_CENTER_ADDR` here.
mod ctm_signatures {
    alloy::sol! {
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
        contract V31MigratorFacet {
            constructor(uint256 _l1ChainId, bool _isTestnet);
        }
        contract V31ChainTypeManager {
            constructor(
                address _bridgehub,
                address _interopCenter,
                address _l1BytecodesSupplier,
                address _permissionlessValidator
            );
        }
        contract V31DualVerifier {
            constructor(address _fflonkVerifier, address _plonkVerifier);
        }
        contract V31ZKsyncOSDualVerifier {
            constructor(address _fflonkVerifier, address _plonkVerifier, address _initialOwner);
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
        contract V31ValidatorTimelock {
            constructor(address _bridgehubAddr);
        }
        contract V31PermissionlessValidator {
            function initialize();
        }
        contract V31BytecodesSupplier {
            function initialize();
        }
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

/// Core proxies whose EIP-1967 admin slot must match the ecosystem
/// `transparent_proxy_admin`.
/// These are the proxies that the v31 governance stage 1 calls upgrade.
const CORE_PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN: &[&str] = &[
    "bridgehub_proxy",
    "l1_nullifier_proxy",
    "l1_asset_router_proxy",
    "native_token_vault",
    "message_root_proxy",
    "ctm_deployment_tracker_proxy",
    "chain_asset_handler_proxy",
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
    verify_v31_proxy_admins(artifact, verifiers, result).await?;
    verify_v31_core_wiring(verifiers, result).await;
    verify_v31_timer_admin_state(artifact, verifiers, result).await?;
    verify_v31_ctm_permissionless_validator(artifact, verifiers, result).await?;

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

    // Constructor args that are not directly present in the artifact are
    // read from live contracts. The artifact is still the source for the
    // deployed implementation/proxy addresses being checked.
    let bridgehub_addr = verifiers.bridgehub_address;
    let bridgehub = BridgehubContract::new(bridgehub_addr, provider.clone());
    let asset_router_proxy = bridgehub.assetRouter().call().await.unwrap_or_else(|err| {
        panic!("Failed to call Bridgehub.assetRouter() for provenance: {err}")
    });
    let l1_asset_router = L1AssetRouter::new(asset_router_proxy, provider.clone());
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

    let governance = bridgehub
        .owner()
        .call()
        .await
        .context("calling Bridgehub.owner() for v31 provenance")?;

    let core_context = CoreProvenanceContext {
        bridgehub_addr,
        asset_router_proxy,
        weth,
        nullifier,
        ntv_proxy,
        era_diamond_proxy,
        governance,
    };
    verify_core_provenance(
        artifact,
        verifiers,
        era_chain_id,
        legacy_gateway_chain_id,
        result,
        core_context,
    )
    .await?;

    for ctm in &artifact.ctms {
        verify_ctm_provenance(
            artifact,
            ctm,
            verifiers,
            era_chain_id,
            l1_chain_id,
            result,
            core_context,
        )
        .await?;
    }

    Ok(())
}

#[derive(Clone, Copy)]
struct CoreProvenanceContext {
    bridgehub_addr: Address,
    asset_router_proxy: Address,
    weth: Address,
    nullifier: Address,
    ntv_proxy: Address,
    era_diamond_proxy: Address,
    governance: Address,
}

async fn verify_core_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    era_chain_id: u64,
    legacy_gateway_chain_id: u64,
    result: &mut VerificationResult,
    context: CoreProvenanceContext,
) -> Result<()> {
    use core_signatures::*;
    result.print_info("-- Core deployment provenance --");

    let core = &artifact.core;
    let in_bh =
        |last: &str| required_address(core, "core", &["upgrade_addresses", "bridgehub", last]);
    let in_bridges =
        |last: &str| required_address(core, "core", &["upgrade_addresses", "bridges", last]);

    let chain_asset_handler_impl = in_bh("chain_asset_handler_implementation_addr")?;
    let chain_asset_handler_proxy = in_bh("chain_asset_handler_proxy_addr")?;
    let message_root_impl = in_bh("message_root_implementation_addr")?;
    let message_root_proxy = in_bh("message_root_proxy_addr")?;
    let ntv_impl = required_address(
        core,
        "core",
        &[
            "upgrade_addresses",
            "native_token_vault_implementation_addr",
        ],
    )?;
    let ctmdt_impl = in_bh("ctm_deployment_tracker_implementation_addr")?;
    let tracker_impl = in_bh("l1_asset_tracker_implementation_addr")?;
    let tracker_proxy = in_bh("l1_asset_tracker_proxy_addr")?;
    let asset_router_impl = in_bridges("l1_asset_router_implementation_addr")?;
    let nullifier_impl = in_bridges("l1_nullifier_implementation_addr")?;
    let bridgehub_impl = in_bh("bridgehub_implementation_addr")?;
    let crs = in_bh("chain_registration_sender_implementation_addr")?;
    let deployer = required_address(&artifact.misc, "misc", &["deployer_addr"])?;
    let core_proxy_admin = required_address(
        core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    // L1MessageRoot has a stage-sepolia variant with the same constructor
    // signature but different runtime bytecode; pick whichever the CREATE2
    // deploy was actually identified as.
    let message_root_file = pick_known_variant(
        verifiers,
        &message_root_impl,
        &["l1-contracts/L1MessageRootStageSepolia"],
        "l1-contracts/L1MessageRoot",
    );

    // L1AssetTracker impl args are reused for the TUPP impl check below.
    let tracker_ctor_args = V31L1AssetTracker::constructorCall::new((
        context.bridgehub_addr,
        context.ntv_proxy,
        message_root_proxy,
    ))
    .abi_encode();

    // Single dispatch table: (address, encoded ctor args, expected file).
    let checks: Vec<(Address, Vec<u8>, &str)> = vec![
        // L1ChainAssetHandler impl(_owner=governance, _bridgehub).
        (
            chain_asset_handler_impl,
            V31L1ChainAssetHandler::constructorCall::new((
                context.governance,
                context.bridgehub_addr,
            ))
            .abi_encode(),
            "l1-contracts/L1ChainAssetHandler",
        ),
        // L1MessageRoot(_bridgehub, _eraGatewayChainId, _chainAssetHandler).
        // Stage Sepolia uses the `L1MessageRootStageSepolia` variant; same
        // ctor signature, different runtime bytecode.
        (
            message_root_impl,
            V31L1MessageRoot::constructorCall::new((
                context.bridgehub_addr,
                U256::from(legacy_gateway_chain_id),
                chain_asset_handler_proxy,
            ))
            .abi_encode(),
            message_root_file,
        ),
        // L1NativeTokenVault impl(weth, assetRouter, nullifier).
        (
            ntv_impl,
            V31L1NativeTokenVault::constructorCall::new((
                context.weth,
                context.asset_router_proxy,
                context.nullifier,
            ))
            .abi_encode(),
            "l1-contracts/L1NativeTokenVault",
        ),
        // CTMDeploymentTracker impl(bridgehub, l1AssetRouter).
        (
            ctmdt_impl,
            V31CTMDeploymentTracker::constructorCall::new((
                context.bridgehub_addr,
                context.asset_router_proxy,
            ))
            .abi_encode(),
            "l1-contracts/CTMDeploymentTracker",
        ),
        // L1AssetTracker impl(bridgehub, ntv, messageRoot).
        // Args reused below for the TUPP impl check.
        (
            tracker_impl,
            tracker_ctor_args.clone(),
            "l1-contracts/L1AssetTracker",
        ),
        // L1AssetRouter impl(weth, bridgehub, nullifier, eraChainId, eraDiamondProxy).
        (
            asset_router_impl,
            V31L1AssetRouter::constructorCall::new((
                context.weth,
                context.bridgehub_addr,
                context.nullifier,
                U256::from(era_chain_id),
                context.era_diamond_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1AssetRouter",
        ),
        // L1Nullifier impl(bridgehub, messageRoot, eraChainId, eraDiamondProxy).
        (
            nullifier_impl,
            V31L1Nullifier::constructorCall::new((
                context.bridgehub_addr,
                message_root_proxy,
                U256::from(era_chain_id),
                context.era_diamond_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1Nullifier",
        ),
        // L1Bridgehub impl(_owner=governance, _maxNumberOfZKChains).
        (
            bridgehub_impl,
            V31L1Bridgehub::constructorCall::new((
                context.governance,
                U256::from(MAX_NUMBER_OF_ZK_CHAINS),
            ))
            .abi_encode(),
            "l1-contracts/L1Bridgehub",
        ),
        // ChainRegistrationSender(bridgehub). Deployed once by `CoreUpgrade_v31`
        // and surfaced as `[core.upgrade_addresses.bridgehub]
        // chain_registration_sender_implementation_addr`.
        (
            crs,
            V31ChainRegistrationSender::constructorCall::new((context.bridgehub_addr,))
                .abi_encode(),
            "l1-contracts/ChainRegistrationSender",
        ),
    ];
    for (addr, args, file) in &checks {
        result.expect_create2_params(verifiers, addr, args.as_slice(), file);
    }

    // L1AssetTracker TransparentUpgradeableProxy(impl, proxyAdmin, initialize(deployer)).
    result
        .expect_create2_params_proxy_with_bytecode(
            verifiers,
            &tracker_proxy,
            V31L1AssetTracker::initializeCall::new((deployer,)).abi_encode(),
            core_proxy_admin,
            tracker_ctor_args,
            "l1-contracts/L1AssetTracker",
        )
        .await;

    Ok(())
}

async fn verify_ctm_provenance(
    artifact: &EcosystemUpgradeArtifact,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    era_chain_id: u64,
    l1_chain_id: u64,
    result: &mut VerificationResult,
    context: CoreProvenanceContext,
) -> Result<()> {
    use ctm_signatures::*;

    verify_ctm_base_provenance(artifact, ctm, verifiers, l1_chain_id, result)?;

    let bridgehub_addr = context.bridgehub_addr;
    let label = ctm.flavor.label();
    result.print_info(&format!("-- CTM deployment provenance: {label} --"));

    let scope = format!("ctms.{label}");
    let in_st = |last: &str| required_address(&ctm.value, &scope, &["state_transition", last]);
    let in_dep = |last: &str| required_address(&ctm.value, &scope, &["deployed_addresses", last]);

    let committer = in_st("committer_facet_addr")?;
    let mailbox = in_st("mailbox_facet_addr")?;
    let migrator = in_st("migrator_facet_addr")?;
    let eip7702 = in_st("eip7702_checker_addr")?;
    let timer = in_dep("l1_governance_upgrade_timer")?;
    let ctm_proxy = in_st("chain_type_manager_proxy")?;
    let stage_validator = in_dep("upgrade_stage_validator")?;
    let timer_governance =
        required_address(&ctm.value, &scope, &["admin", "timer_governance_addr"])?;
    let ecosystem_admin = required_address(&ctm.value, &scope, &["admin", "ecosystem_admin_addr"])?;
    let bytecodes_supplier = in_st("bytecodes_supplier_addr")?;
    let permissionless_validator = in_st("permissionless_validator_addr")?;
    let ctm_impl = in_st("chain_type_manager_implementation_addr")?;
    let validator_timelock_impl = in_st("validator_timelock_implementation_addr")?;
    let transparent_proxy_admin = in_dep("transparent_proxy_admin")?;
    let chain_asset_handler = required_address(
        &artifact.core,
        "core",
        &[
            "upgrade_addresses",
            "bridgehub",
            "chain_asset_handler_proxy_addr",
        ],
    )?;

    let ctm_file = match ctm.flavor {
        CtmFlavor::Era => "l1-contracts/EraChainTypeManager",
        CtmFlavor::ZksyncOs => "l1-contracts/ZKsyncOSChainTypeManager",
    };

    // Single dispatch table: (address, encoded ctor args, expected file).
    let checks: Vec<(Address, Vec<u8>, &str)> = vec![
        // CommitterFacet(_l1ChainId).
        (
            committer,
            V31CommitterFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/CommitterFacet",
        ),
        // MailboxFacet(eraChainId, l1ChainId, chainAssetHandler, eip7702Checker, isTestnet).
        (
            mailbox,
            V31MailboxFacet::constructorCall::new((
                U256::from(era_chain_id),
                U256::from(l1_chain_id),
                chain_asset_handler,
                eip7702,
                ctm.contracts_config.is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MailboxFacet",
        ),
        // MigratorFacet(_l1ChainId, _isTestnet).
        (
            migrator,
            V31MigratorFacet::constructorCall::new((
                U256::from(l1_chain_id),
                ctm.contracts_config.is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MigratorFacet",
        ),
        // GovernanceUpgradeTimer(initialDelay, maxAdditionalDelay, timerGovernance, initialOwner).
        (
            timer,
            V31GovernanceUpgradeTimer::constructorCall::new((
                U256::from(ctm.contracts_config.governance_upgrade_timer_initial_delay),
                U256::from(GOVERNANCE_TIMER_MAX_ADDITIONAL_DELAY_SECONDS),
                timer_governance,
                ecosystem_admin,
            ))
            .abi_encode(),
            "l1-contracts/GovernanceUpgradeTimer",
        ),
        // UpgradeStageValidator(chainTypeManager=ctm_proxy, newProtocolVersion).
        (
            stage_validator,
            V31UpgradeStageValidator::constructorCall::new((
                ctm_proxy,
                U256::from(ctm.contracts_config.new_protocol_version),
            ))
            .abi_encode(),
            "l1-contracts/UpgradeStageValidator",
        ),
        // ChainTypeManager impl(bridgehub, interopCenter, bytecodesSupplier, permissionlessValidator).
        // `L2_INTEROP_CENTER_ADDR` is the L2 built-in address, intentionally
        // embedded in an L1-side immutable — the CTM only ever uses it when
        // constructing L2-aliased messages (see ChainTypeManagerBase.sol).
        (
            ctm_impl,
            V31ChainTypeManager::constructorCall::new((
                bridgehub_addr,
                L2_INTEROP_CENTER_ADDR,
                bytecodes_supplier,
                permissionless_validator,
            ))
            .abi_encode(),
            ctm_file,
        ),
        // ValidatorTimelock impl(bridgehub). Deployed once per CTM by
        // `CTMUpgrade_v31`; stage-1 governance swaps this behind the per-CTM
        // ValidatorTimelock proxy.
        (
            validator_timelock_impl,
            V31ValidatorTimelock::constructorCall::new((bridgehub_addr,)).abi_encode(),
            "l1-contracts/ValidatorTimelock",
        ),
    ];
    for (addr, args, file) in &checks {
        result.expect_create2_params(verifiers, addr, args.as_slice(), file);
    }

    // BytecodesSupplier TransparentUpgradeableProxy(impl, proxyAdmin, initialize()).
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

    // PermissionlessValidator TransparentUpgradeableProxy(impl, proxyAdmin, initialize()).
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

    Ok(())
}

async fn verify_l1_chain_id(verifiers: &Verifiers, result: &mut VerificationResult) {
    match verifiers.network_verifier.try_get_l1_chain_id().await {
        Ok(chain_id) => result.report_ok(&format!("L1 RPC chain id: {chain_id}")),
        Err(err) => result.report_error(&format!("Failed to fetch L1 RPC chain id: {err}")),
    }
}

async fn verify_v31_proxy_admins(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let expected_core_admin = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    result
        .expect_deployed_bytecode(verifiers, &expected_core_admin, "TransparentProxyAdmin")
        .await;

    let admin_slot = match FixedBytes::<32>::from_hex(EIP1967_PROXY_ADMIN_SLOT) {
        Ok(slot) => slot,
        Err(err) => {
            result.report_error(&format!("Invalid EIP-1967 admin slot literal: {err}"));
            return Ok(());
        }
    };

    let provider = verifiers.network_verifier.get_l1_provider();
    for proxy_name in CORE_PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN {
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
        if actual_admin == expected_core_admin {
            result.report_ok(&format!(
                "Proxy admin for {proxy_name} matches transparent_proxy_admin"
            ));
        } else {
            result.report_error(&format!(
                "Proxy admin mismatch for {proxy_name}: expected {expected_core_admin}, got {actual_admin}"
            ));
        }
    }

    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let expected_admin = required_address(
            &ctm.value,
            &scope,
            &["deployed_addresses", "transparent_proxy_admin"],
        )?;
        let proxy_addr = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;

        let raw = match provider
            .get_storage_at(proxy_addr, U256::from_be_bytes(admin_slot.0))
            .await
        {
            Ok(value) => value.to_be_bytes::<32>(),
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping proxy-admin check for {label}.chain_type_manager_proxy; eth_getStorageAt failed: {err}"
                ));
                continue;
            }
        };
        let actual_admin = Address::from_slice(&raw[12..]);
        if actual_admin == expected_admin {
            result.report_ok(&format!(
                "Proxy admin for {label}.chain_type_manager_proxy matches {label}.transparent_proxy_admin"
            ));
        } else {
            result.report_error(&format!(
                "Proxy admin mismatch for {label}.chain_type_manager_proxy: expected {expected_admin}, got {actual_admin}"
            ));
        }
    }

    Ok(())
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
        let tracker = Ownable::new(*expected_tracker, provider.clone());
        match tracker.owner().call().await {
            Ok(owner) => result.report_ok(&format!("AssetTracker owner: {owner}")),
            Err(err) => result.report_warn(&format!(
                "Skipping AssetTracker.owner() check; call failed: {err}"
            )),
        }
    }
}

/// Sanity-check the live ownership state that should match the timer
/// constructor addresses recorded under `[ctms.<flavor>.admin]`.
///
/// `CtmArtifact.value` is the raw `[ctms.<flavor>]` TOML table, so these
/// fields do not need a dedicated typed artifact struct to be loadable.
async fn verify_v31_timer_admin_state(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    let bridgehub = BridgehubContract::new(verifiers.bridgehub_address, provider.clone());
    let bridgehub_owner = match bridgehub.owner().call().await {
        Ok(owner) => Some(owner),
        Err(err) => {
            result.report_error(&format!(
                "Failed to call Bridgehub.owner() for GovernanceUpgradeTimer admin checks: {err}"
            ));
            None
        }
    };

    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let expected_timer_governance =
            required_address(&ctm.value, &scope, &["admin", "timer_governance_addr"])?;
        let expected_ecosystem_admin =
            required_address(&ctm.value, &scope, &["admin", "ecosystem_admin_addr"])?;

        if let Some(actual_timer_governance) = bridgehub_owner {
            if actual_timer_governance == expected_timer_governance {
                result.report_ok(&format!(
                    "{label}.admin.timer_governance_addr matches Bridgehub.owner()"
                ));
            } else {
                result.report_error(&format!(
                    "{label}.admin.timer_governance_addr mismatch: artifact {expected_timer_governance}, Bridgehub.owner() {actual_timer_governance}"
                ));
            }
        }

        let ctm_proxy = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;
        let ctm_owner = ChainTypeManager::new(ctm_proxy, provider.clone())
            .owner()
            .call()
            .await;
        match ctm_owner {
            Ok(actual_ecosystem_admin) if actual_ecosystem_admin == expected_ecosystem_admin => {
                result.report_ok(&format!(
                    "{label}.admin.ecosystem_admin_addr matches chain_type_manager_proxy.owner()"
                ));
            }
            Ok(actual_ecosystem_admin) => result.report_error(&format!(
                "{label}.admin.ecosystem_admin_addr mismatch: artifact {expected_ecosystem_admin}, chain_type_manager_proxy.owner() {actual_ecosystem_admin}"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.chain_type_manager_proxy.owner() for GovernanceUpgradeTimer admin checks: {err}"
            )),
        }
    }

    Ok(())
}

async fn verify_v31_ctm_permissionless_validator(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let ctm_impl = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_implementation_addr"],
        )?;
        let expected_permissionless_validator = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "permissionless_validator_addr"],
        )?;

        if expected_permissionless_validator == Address::ZERO {
            result.report_error(&format!(
                "{label}.permissionless_validator_addr is address(0); v31 CTM implementations must be constructed with a PermissionlessValidator proxy"
            ));
            continue;
        }

        let ctm_view = ChainTypeManager::new(ctm_impl, provider.clone());
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
    Ok(())
}

/// Per-CTM, per-flavor provenance for the contracts that ship one copy per
/// CTM (verifiers, DiamondInit, default_upgrade, genesis_upgrade, getters/
/// executor/admin facets, ServerNotifier, EIP7702Checker). The v31 upgrade
/// deploys these once for Era and once for ZKsyncOS, so verification
/// iterates per CTM and uses each CTM's own `flavor`.
///
/// All required addresses come from the CTM's own `[ctms.<flavor>]`
/// section via `required_address`.
fn verify_ctm_base_provenance(
    artifact: &EcosystemUpgradeArtifact,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    l1_chain_id: u64,
    result: &mut VerificationResult,
) -> Result<()> {
    use ctm_signatures::*;

    let is_zksync_os = matches!(ctm.flavor, CtmFlavor::ZksyncOs);
    let scope = format!("ctms.{}", ctm.flavor.label());

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

    // No-arg CTM contracts. `eip7702_checker_addr` lives in the da-contracts
    // tree; everything else is l1-contracts.
    let no_args: &[(&[&str], &str)] = &[
        // L1GenesisUpgrade() — no ctor args.
        (
            &["state_transition", "genesis_upgrade_addr"],
            "l1-contracts/L1GenesisUpgrade",
        ),
        // GettersFacet() — no ctor args.
        (
            &["state_transition", "getters_facet_addr"],
            "l1-contracts/GettersFacet",
        ),
        // {Era,ZKsyncOS}SettlementLayerV31Upgrade() — no ctor args.
        (
            &["state_transition", "default_upgrade_addr"],
            default_upgrade_file,
        ),
        // {Era,ZKsyncOS}VerifierPlonk() — no ctor args.
        (
            &["state_transition", "verifier_plonk_addr"],
            verifier_plonk_file,
        ),
        // {Era,ZKsyncOS}VerifierFflonk() — no ctor args.
        (
            &["state_transition", "verifier_fflonk_addr"],
            verifier_fflonk_file,
        ),
        // ServerNotifier impl() — no ctor args; owner set later via initialize.
        (
            &["state_transition", "server_notifier_implementation_addr"],
            "l1-contracts/ServerNotifier",
        ),
        // EIP7702Checker() — no ctor args; artifact comes from da-contracts.
        (
            &["state_transition", "eip7702_checker_addr"],
            "da-contracts/EIP7702Checker",
        ),
    ];
    for (path, expected_file) in no_args {
        let addr = required_address(&ctm.value, &scope, path)?;
        result.expect_create2_params(verifiers, &addr, Vec::<u8>::new(), expected_file);
    }

    // DiamondInit(bool _isZKsyncOS) — encoded as a single 32-byte word.
    let diamond_init = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "diamond_init_addr"],
    )?;
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

    // ExecutorFacet(l1ChainId) — file is shared across flavors, but the
    // address is per-CTM.
    let executor = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "executor_facet_addr"],
    )?;
    result.expect_create2_params(
        verifiers,
        &executor,
        V31ExecutorFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
        "l1-contracts/ExecutorFacet",
    );

    // AdminFacet(l1ChainId, rollupDAManager) — rollupDAManager is per-CTM.
    let admin = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "admin_facet_addr"],
    )?;
    let rollup_da_manager = required_address(
        &ctm.value,
        &scope,
        &["deployed_addresses", "l1_rollup_da_manager"],
    )?;
    result.expect_create2_params(
        verifiers,
        &admin,
        V31AdminFacet::constructorCall::new((U256::from(l1_chain_id), rollup_da_manager))
            .abi_encode(),
        "l1-contracts/AdminFacet",
    );

    // DualVerifier(fflonk, plonk) / *TestnetVerifier.
    // Stage / testnet environments deploy the `*TestnetVerifier` flavor
    // instead of `*DualVerifier`; pick whichever the CREATE2 deploy was
    // actually identified as.
    //
    // ZKsyncOS verifiers take a third `_initialOwner` constructor arg: the
    // deployer EOA from `DeployCTMUtils.verifierOwner = getBroadcasterAddress()`.
    let verifier = required_address(&ctm.value, &scope, &["state_transition", "verifier_addr"])?;
    let fflonk = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "verifier_fflonk_addr"],
    )?;
    let plonk = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "verifier_plonk_addr"],
    )?;
    let verifier_file = pick_known_variant(
        verifiers,
        &verifier,
        &[testnet_verifier_file],
        dual_verifier_file,
    );
    let encoded = if is_zksync_os {
        let initial_owner = required_address(&artifact.misc, "misc", &["deployer_addr"])?;
        V31ZKsyncOSDualVerifier::constructorCall::new((fflonk, plonk, initial_owner)).abi_encode()
    } else {
        V31DualVerifier::constructorCall::new((fflonk, plonk)).abi_encode()
    };
    result.expect_create2_params(verifiers, &verifier, encoded, verifier_file);

    Ok(())
}

/// Pick the file name that matches the CREATE2 deployment record at
/// `address`. Returns the first candidate whose name equals the recorded
/// file, falling back to `default_file` if none match (or if the address
/// isn't in the create2 map).
///
/// Used where multiple Solidity contract sources share a constructor
/// signature and only the deployed bytecode tells them apart:
/// `L1MessageRoot` vs `L1MessageRootStageSepolia`, `DualVerifier` vs
/// `*TestnetVerifier`.
fn pick_known_variant<'a>(
    verifiers: &Verifiers,
    address: &Address,
    candidates: &[&'a str],
    default_file: &'a str,
) -> &'a str {
    let resolved = verifiers
        .network_verifier
        .create2_known_bytecodes
        .get(address)
        .cloned();
    match resolved.as_deref() {
        Some(file) => candidates
            .iter()
            .copied()
            .find(|c| *c == file)
            .unwrap_or(default_file),
        None => default_file,
    }
}

/// Resolves a nested address from a toml value. `scope` is used only for
/// error messages (e.g. `"core"`, `"misc"`, `"ctms.era"`); `path` is the
/// chain of keys to walk into `value`.
fn required_address(value: &toml::Value, scope: &str, path: &[&str]) -> Result<Address> {
    let path_label = format!("{scope}.{}", path.join("."));
    let mut current = value;
    for segment in path {
        let Some(next) = current.get(*segment) else {
            anyhow::bail!("{path_label} is required");
        };
        current = next;
    }

    let Some(raw) = current.as_str() else {
        anyhow::bail!("{path_label} must be an address string");
    };

    Address::from_str(raw).with_context(|| format!("{path_label} is not a valid address"))
}
