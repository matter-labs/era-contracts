use anyhow::Result;

use crate::upgrade_verification::{
    artifacts::{
        optional_address_in_value, required_address_in_value as required_address, CtmFlavor,
        EcosystemUpgradeArtifact,
    },
    constants::EIP1967_PROXY_ADMIN_SLOT,
    verifiers::{VerificationResult, Verifiers},
    versions::v33::{
        utils::{
            fee_param_verifier::{FeeParamVerifier, FeeParams},
            network_verifier::{
                Bridgehub as BridgehubContract, ChainRegistrationSender, ChainTypeManager,
                L1AssetRouter, Ownable, Ownable2Step, ValidatorTimelock, ZKChainFeeParams,
            },
        },
        MAX_PRIORITY_TX_GAS_LIMIT, STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID,
    },
};

use alloy::{
    hex::FromHex,
    primitives::{Address, FixedBytes, U256},
    providers::Provider,
};

const CREATE2_FACTORY_CONTRACT_NAME: &str = "Create2Factory";

// `DiamondInit` writes the default fee params from `Config.sol` into
// `ZKChainStorage.s.feeParams`; this slot matches the v33 storage layout.
const FEE_PARAMS_STORAGE_SLOT: u64 = 38;
const MAINNET_VALIDATOR_TIMELOCK_EXECUTION_DELAY_SECONDS: u32 = 10_800;
const TESTNET_VALIDATOR_TIMELOCK_EXECUTION_DELAY_SECONDS: u32 = 0;

/// Core proxies whose EIP-1967 admin slot must match the ecosystem
/// `transparent_proxy_admin`.
/// These are the proxies that the v33 governance stage 1 calls upgrade.
const CORE_PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN: &[&str] = &[
    "bridgehub_proxy",
    "l1_nullifier_proxy",
    "l1_asset_router_proxy",
    "native_token_vault",
    "message_root_proxy",
    "ctm_deployment_tracker_proxy",
    "chain_asset_handler_proxy",
];

fn expect_address_eq(
    result: &mut VerificationResult,
    label: &str,
    actual: Address,
    expected: Address,
) {
    if actual == expected {
        result.report_ok(&format!("{label} matches expected address ({expected})"));
    } else {
        result.report_error(&format!(
            "{label} mismatch: expected {expected}, got {actual}"
        ));
    }
}

fn expect_debug_eq<T: std::fmt::Debug + PartialEq>(
    result: &mut VerificationResult,
    label: &str,
    actual: &T,
    expected: &T,
) {
    if actual == expected {
        result.report_ok(&format!("{label} matches expected value ({expected:?})"));
    } else {
        result.report_error(&format!(
            "{label} mismatch: expected {expected:?}, got {actual:?}"
        ));
    }
}

fn expect_fee_params_eq(result: &mut VerificationResult, actual: &FeeParams, expected: &FeeParams) {
    expect_debug_eq(
        result,
        "Era feeParams.pubdataPricingMode",
        &actual.pubdataPricingMode,
        &expected.pubdataPricingMode,
    );
    expect_debug_eq(
        result,
        "Era feeParams.batchOverheadL1Gas",
        &actual.batchOverheadL1Gas,
        &expected.batchOverheadL1Gas,
    );
    expect_debug_eq(
        result,
        "Era feeParams.maxPubdataPerBatch",
        &actual.maxPubdataPerBatch,
        &expected.maxPubdataPerBatch,
    );
    expect_debug_eq(
        result,
        "Era feeParams.maxL2GasPerBatch",
        &actual.maxL2GasPerBatch,
        &expected.maxL2GasPerBatch,
    );
    expect_debug_eq(
        result,
        "Era feeParams.priorityTxMaxPubdata",
        &actual.priorityTxMaxPubdata,
        &expected.priorityTxMaxPubdata,
    );
    expect_debug_eq(
        result,
        "Era feeParams.minimalL2GasPrice",
        &actual.minimalL2GasPrice,
        &expected.minimalL2GasPrice,
    );
}

/// RPC state checks
///
/// This is intentionally the *non-overlapping* slice of legacy PUVT's
/// post-deploy work — it covers checks that aren't subsumed by Phase 6
/// (deployment provenance):
/// - The L1 RPC chain id (sanity).
/// - Runtime bytecode at the configured Create2Factory address.
/// - Runtime bytecode at the ecosystem `transparent_proxy_admin` address.
/// - EIP-1967 proxy-admin slot for every v33 stage-1 proxy → must equal the
///   ecosystem `transparent_proxy_admin`.
/// - Pre-upgrade core wiring: AssetRouter owner / legacy bridge / NTV and
///   Bridgehub / ChainAssetHandler wiring.
/// - ValidatorTimelock owner and execution delay.
/// - Era fee params and priority-tx max gas limit.
///
/// Per-implementation deployed-bytecode and constructor-arg checks live in
/// deployment provenance: they use init bytecode + constructor args (via
/// `expect_create2_params`), which handles Solidity `immutable` substitution
/// correctly. The flat-table runtime-hash check previously here was strictly
/// weaker and produced misleading errors for every contract with immutables;
/// Phase 6 supersedes it.
///
/// Bytecode-supplier `publishingBlock` checks for the L2 upgrade tx
/// `factoryDeps` are restored separately inside
/// `set_new_version_upgrade::verify_factory_deps` so they sit alongside the
/// rest of the L2 upgrade tx checks.
pub(crate) async fn verify_v33_artifact_state(
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
    verify_v33_proxy_admins(artifact, verifiers, result).await?;
    verify_v33_core_wiring(artifact, verifiers, result).await?;
    verify_v33_validator_timelocks(artifact, verifiers, result).await?;
    verify_v33_era_fee_params(verifiers, result).await;
    verify_v33_timer_admin_state(artifact, verifiers, result).await?;
    verify_v33_ctm_permissionless_validator(artifact, verifiers, result).await?;
    verify_v33_ctm_flavor(artifact, verifiers, result).await?;
    verify_v33_chain_settlement_layers(verifiers, result).await;

    Ok(())
}

async fn verify_l1_chain_id(verifiers: &Verifiers, result: &mut VerificationResult) {
    match verifiers.network_verifier.try_get_l1_chain_id().await {
        Ok(chain_id) if chain_id == verifiers.expected_l1_chain_id => result.report_ok(&format!(
            "L1 RPC chain id matches env expected ({chain_id})"
        )),
        Ok(chain_id) => result.report_error(&format!(
            "L1 RPC chain id mismatch: expected {} (from permanent-values), got {chain_id}",
            verifiers.expected_l1_chain_id
        )),
        Err(err) => result.report_error(&format!("Failed to fetch L1 RPC chain id: {err}")),
    }
}

async fn verify_v33_proxy_admins(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let expected_core_admin = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    // The core `ProxyAdmin` is not deployed by this upgrade — it predates the
    // release, so its bytecode is whatever compiler and OpenZeppelin version
    // built it back then and will not match this repo's `TransparentProxyAdmin`
    // artifact. What actually has to hold for the stage-1 proxy swaps to be
    // executable is checked instead: the admin has code, and its owner is the
    // governance that issues those `upgrade` calls. Every core proxy pointing
    // at this admin is verified below.
    if verifiers
        .network_verifier
        .get_bytecode_hash_at(&expected_core_admin)
        .await
        == FixedBytes::<32>::ZERO
    {
        result.report_error(&format!(
            "transparent_proxy_admin {expected_core_admin} has no code on L1"
        ));
    } else {
        match Ownable::new(
            expected_core_admin,
            verifiers.network_verifier.get_l1_provider(),
        )
        .owner()
        .call()
        .await
        {
            Ok(actual) => expect_address_eq(
                result,
                "transparent_proxy_admin.owner()",
                actual,
                verifiers.bridgehub_owner,
            ),
            Err(err) => result.report_error(&format!(
                "Failed to call transparent_proxy_admin.owner(): {err}"
            )),
        }
    }

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
        for (proxy_label, proxy_path) in [
            ("chain_type_manager_proxy", "chain_type_manager_proxy"),
            ("validator_timelock_addr", "validator_timelock_addr"),
        ] {
            let proxy_addr =
                required_address(&ctm.value, &scope, &["state_transition", proxy_path])?;
            let raw = match provider
                .get_storage_at(proxy_addr, U256::from_be_bytes(admin_slot.0))
                .await
            {
                Ok(value) => value.to_be_bytes::<32>(),
                Err(err) => {
                    result.report_warn(&format!(
                        "Skipping proxy-admin check for {label}.{proxy_label}; eth_getStorageAt failed: {err}"
                    ));
                    continue;
                }
            };
            let actual_admin = Address::from_slice(&raw[12..]);
            if actual_admin == expected_admin {
                result.report_ok(&format!(
                    "Proxy admin for {label}.{proxy_label} matches {label}.transparent_proxy_admin"
                ));
            } else {
                result.report_error(&format!(
                    "Proxy admin mismatch for {label}.{proxy_label}: expected {expected_admin}, got {actual_admin}"
                ));
            }
        }
    }

    Ok(())
}

async fn verify_v33_core_wiring(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    let bridgehub = BridgehubContract::new(verifiers.bridgehub_address, provider.clone());
    let bridgehub_owner = verifiers.bridgehub_owner;

    let expected_asset_router = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "bridges", "l1_asset_router_proxy_addr"],
    )?;
    let expected_ctm_deployment_tracker = required_address(
        &artifact.core,
        "core",
        &[
            "upgrade_addresses",
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
        ],
    )?;
    // v33's core prepare no longer records the legacy ERC20 bridge, so this is absent on a v33
    // artifact. The upgrade does not touch `L1AssetRouter.legacyBridge()` either way; when the
    // artifact does carry the address we still cross-check it.
    let expected_legacy_bridge = optional_address_in_value(
        &artifact.core,
        "core",
        &["upgrade_addresses", "bridges", "erc20_bridge_proxy_addr"],
    )?;
    let expected_ntv = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "native_token_vault_addr"],
    )?;
    let expected_chain_registration_sender = required_address(
        &artifact.core,
        "core",
        &[
            "upgrade_addresses",
            "bridgehub",
            "chain_registration_sender_proxy_addr",
        ],
    )?;
    let expected_chain_asset_handler = required_address(
        &artifact.core,
        "core",
        &[
            "upgrade_addresses",
            "bridgehub",
            "chain_asset_handler_proxy_addr",
        ],
    )?;
    let expected_message_root = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "bridgehub", "message_root_proxy_addr"],
    )?;

    let asset_router = L1AssetRouter::new(expected_asset_router, provider.clone());
    let asset_router_owner = Ownable::new(expected_asset_router, provider.clone());
    match bridgehub.assetRouter().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "Bridgehub.assetRouter()",
            actual,
            expected_asset_router,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call Bridgehub.assetRouter() for core wiring checks: {err}"
        )),
    }
    match bridgehub.sharedBridge().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "Bridgehub.sharedBridge()",
            actual,
            expected_asset_router,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call Bridgehub.sharedBridge() for core wiring checks: {err}"
        )),
    }
    match bridgehub.l1CtmDeployer().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "Bridgehub.l1CtmDeployer()",
            actual,
            expected_ctm_deployment_tracker,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call Bridgehub.l1CtmDeployer() for core wiring checks: {err}"
        )),
    }

    match asset_router_owner.owner().call().await {
        Ok(actual) => expect_address_eq(result, "L1AssetRouter.owner()", actual, bridgehub_owner),
        Err(err) => result.report_error(&format!(
            "Failed to call L1AssetRouter.owner() for core wiring checks: {err}"
        )),
    }
    let era_chain_id = U256::from(verifiers.era_chain_id);
    match asset_router.ERA_CHAIN_ID().call().await {
        Ok(actual) => {
            expect_debug_eq(result, "L1AssetRouter.eraChainId()", &actual, &era_chain_id);
        }
        Err(err) => result.report_error(&format!(
            "Failed to call L1AssetRouter.eraChainId() for core wiring checks: {err}"
        )),
    };

    match (
        expected_legacy_bridge,
        asset_router.legacyBridge().call().await,
    ) {
        (Some(expected), Ok(actual)) => {
            expect_address_eq(result, "L1AssetRouter.legacyBridge()", actual, expected)
        }
        (None, Ok(_)) => result.print_info(
            "L1AssetRouter.legacyBridge(): skipped — artifact records no erc20_bridge_proxy_addr",
        ),
        (_, Err(err)) => result.report_error(&format!(
            "Failed to call L1AssetRouter.legacyBridge() for core wiring checks: {err}"
        )),
    }
    match asset_router.nativeTokenVault().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "L1AssetRouter.nativeTokenVault()",
            actual,
            expected_ntv,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call L1AssetRouter.nativeTokenVault() for core wiring checks: {err}"
        )),
    }

    let chain_registration_sender =
        ChainRegistrationSender::new(expected_chain_registration_sender, provider.clone());
    match chain_registration_sender.BRIDGE_HUB().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "ChainRegistrationSender.BRIDGE_HUB()",
            actual,
            verifiers.bridgehub_address,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call ChainRegistrationSender.BRIDGE_HUB() for core wiring checks: {err}"
        )),
    }
    let chain_registration_sender_ownership =
        Ownable2Step::new(expected_chain_registration_sender, provider.clone());
    // Governance must end up owning the sender, but it can get there two ways: a transfer is
    // still pending (`pendingOwner == governance`, the state right after a fresh deploy), or it
    // was already accepted (`owner == governance`, `pendingOwner == 0`). Asserting only the
    // former fails on an ecosystem that has already completed the handover — testnet has.
    match chain_registration_sender_ownership.pendingOwner().call().await {
        Ok(actual) if actual == bridgehub_owner => expect_address_eq(
            result,
            "ChainRegistrationSender.pendingOwner()",
            actual,
            bridgehub_owner,
        ),
        Ok(_) => match chain_registration_sender_ownership.owner().call().await {
            Ok(owner) => expect_address_eq(
                result,
                "ChainRegistrationSender.owner() (transfer already accepted)",
                owner,
                bridgehub_owner,
            ),
            Err(err) => result.report_error(&format!(
                "Failed to call ChainRegistrationSender.owner() for pre-upgrade ownership checks: {err}"
            )),
        },
        Err(err) => result.report_error(&format!(
            "Failed to call ChainRegistrationSender.pendingOwner() for pre-upgrade ownership checks: {err}"
        )),
    }

    match bridgehub.chainAssetHandler().call().await {
        Ok(actual_chain_asset_handler) => {
            expect_address_eq(
                result,
                "Bridgehub.chainAssetHandler()",
                actual_chain_asset_handler,
                expected_chain_asset_handler,
            );
        }
        Err(err) => result.report_error(&format!(
            "Failed to call Bridgehub.chainAssetHandler() for core wiring checks: {err}"
        )),
    }

    // Bridgehub.messageRoot() ↔ artifact's `message_root_proxy_addr` (L7).
    // The L1Nullifier constructor takes this as its `messageRoot` arg, so a
    // mismatch here means the L1Nullifier was deployed against a different
    // MessageRoot than what the live Bridgehub points at.
    match bridgehub.messageRoot().call().await {
        Ok(actual) => expect_address_eq(
            result,
            "Bridgehub.messageRoot()",
            actual,
            expected_message_root,
        ),
        Err(err) => result.report_error(&format!(
            "Failed to call Bridgehub.messageRoot() for core wiring checks: {err}"
        )),
    }

    // ChainAssetHandler must already be owned by governance (PUH on stage /
    // mainnet) before stage 0/1/2 run — `pauseMigration()`, `setAddresses()`,
    // and `unpauseMigration()` are all owner-gated. We expect governance to be
    // `bridgehub.owner()` (== the PUH proxy on PUH-governed envs).
    let chain_asset_handler_owner = Ownable::new(expected_chain_asset_handler, provider.clone());
    match chain_asset_handler_owner.owner().call().await {
        Ok(actual) => {
            expect_address_eq(result, "ChainAssetHandler.owner()", actual, bridgehub_owner)
        }
        Err(err) => result.report_error(&format!(
            "Failed to call ChainAssetHandler.owner() for pre-upgrade ownership checks: {err}"
        )),
    }

    Ok(())
}

async fn verify_v33_validator_timelocks(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let validator_timelock = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "validator_timelock_addr"],
        )?;
        let chain_type_manager = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;
        let expected_owner =
            required_address(&ctm.value, &scope, &["admin", "timer_governance_addr"])?;
        let expected_delay = if ctm.contracts_config.is_testnet {
            TESTNET_VALIDATOR_TIMELOCK_EXECUTION_DELAY_SECONDS
        } else {
            MAINNET_VALIDATOR_TIMELOCK_EXECUTION_DELAY_SECONDS
        };

        let ctm_view = ChainTypeManager::new(chain_type_manager, provider.clone());
        match ctm_view.validatorTimelockPostV29().call().await {
            Ok(actual) => expect_address_eq(
                result,
                &format!("{label}.ChainTypeManager.validatorTimelockPostV29()"),
                actual,
                validator_timelock,
            ),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.ChainTypeManager.validatorTimelockPostV29(): {err}"
            )),
        }

        let owner_view = Ownable::new(validator_timelock, provider.clone());
        match owner_view.owner().call().await {
            Ok(actual) => expect_address_eq(
                result,
                &format!("{label}.ValidatorTimelock.owner()"),
                actual,
                expected_owner,
            ),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.ValidatorTimelock.owner(): {err}"
            )),
        }

        let timelock_view = ValidatorTimelock::new(validator_timelock, provider.clone());
        match timelock_view.executionDelay().call().await {
            Ok(actual) if actual == expected_delay => result.report_ok(&format!(
                "{label}.ValidatorTimelock.executionDelay() matches expected value ({expected_delay})"
            )),
            Ok(actual) => result.report_error(&format!(
                "{label}.ValidatorTimelock.executionDelay() mismatch: expected {expected_delay}, got {actual}"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.ValidatorTimelock.executionDelay(): {err}"
            )),
        }
    }
    Ok(())
}

async fn verify_v33_era_fee_params(verifiers: &Verifiers, result: &mut VerificationResult) {
    let era_chain_id = verifiers.era_chain_id;
    let diamond = match verifiers
        .network_verifier
        .try_get_chain_diamond_from_bridgehub(verifiers.bridgehub_address, U256::from(era_chain_id))
        .await
    {
        Ok(addr) if addr != Address::ZERO => addr,
        Ok(_) => {
            // An ecosystem whose `ERA_CHAIN_ID` names no registered chain has no Era diamond to
            // read fee params from. Absence, not a mismatch — see `FeeParamVerifier::safe_init`.
            result.print_info(&format!(
                "Era fee params: skipped — Bridgehub.getZKChain({era_chain_id}) returned \
                 address(0), so this ecosystem has no Era diamond"
            ));
            return;
        }
        Err(err) => {
            result.report_error(&format!(
                "Cannot verify Era fee params: Bridgehub.getZKChain({era_chain_id}) failed: {err}"
            ));
            return;
        }
    };

    let provider = verifiers.network_verifier.get_l1_provider();
    let raw = match provider
        .get_storage_at(diamond, U256::from(FEE_PARAMS_STORAGE_SLOT))
        .await
    {
        Ok(value) => value.to_be_bytes::<32>(),
        Err(err) => {
            result.report_error(&format!(
                "Cannot verify Era fee params: eth_getStorageAt({diamond}, slot {FEE_PARAMS_STORAGE_SLOT}) failed: {err}"
            ));
            return;
        }
    };

    let actual_fee_params = match FeeParamVerifier::decode_storage_word(FixedBytes::from(raw)) {
        Ok(value) => value,
        Err(err) => {
            result.report_error(&format!(
                "Cannot verify Era fee params: failed to decode storage slot {FEE_PARAMS_STORAGE_SLOT}: {err}"
            ));
            return;
        }
    };
    expect_fee_params_eq(
        result,
        &actual_fee_params,
        &verifiers.fee_param_verifier.fee_params,
    );

    let chain_getters = ZKChainFeeParams::new(diamond, provider);
    match chain_getters.getPriorityTxMaxGasLimit().call().await {
        Ok(actual) if actual == U256::from(MAX_PRIORITY_TX_GAS_LIMIT) => result.report_ok(
            &format!(
                "Era getPriorityTxMaxGasLimit() matches expected value ({MAX_PRIORITY_TX_GAS_LIMIT})"
            ),
        ),
        Ok(actual) => result.report_error(&format!(
            "Era getPriorityTxMaxGasLimit() mismatch: expected {MAX_PRIORITY_TX_GAS_LIMIT}, got {actual}"
        )),
        Err(err) => result.report_error(&format!(
            "Failed to call Era getPriorityTxMaxGasLimit(): {err}"
        )),
    }
}

/// Sanity-check the live ownership state that should match the timer
/// constructor addresses recorded under `[ctms.<flavor>.admin]`.
///
/// `CtmArtifact.value` is the raw `[ctms.<flavor>]` TOML table, so these
/// fields do not need a dedicated typed artifact struct to be loadable.
async fn verify_v33_timer_admin_state(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    let bridgehub_owner = verifiers.bridgehub_owner;

    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let expected_timer_governance =
            required_address(&ctm.value, &scope, &["admin", "timer_governance_addr"])?;
        let expected_ecosystem_admin =
            required_address(&ctm.value, &scope, &["admin", "ecosystem_admin_addr"])?;

        if bridgehub_owner == expected_timer_governance {
            result.report_ok(&format!(
                "{label}.admin.timer_governance_addr matches Bridgehub.owner()"
            ));
        } else {
            result.report_error(&format!(
                "{label}.admin.timer_governance_addr mismatch: artifact {expected_timer_governance}, Bridgehub.owner() {bridgehub_owner}"
            ));
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

async fn verify_v33_ctm_permissionless_validator(
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
                "{label}.permissionless_validator_addr is address(0); v33 CTM implementations must be constructed with a PermissionlessValidator proxy"
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

/// `isZKsyncOS()` is `external pure` on the v33 CTM impl so it's safe to call
/// directly on the implementation contract (no proxy, no init required). This
/// guards against the artifact mislabeling a ZKsync OS CTM as Era or vice
/// versa — an artifact-side swap that all other per-CTM checks would happily
/// pass through.
async fn verify_v33_ctm_flavor(
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
        let expected = matches!(ctm.flavor, CtmFlavor::ZksyncOs);
        match ChainTypeManager::new(ctm_impl, provider.clone())
            .isZKsyncOS()
            .call()
            .await
        {
            Ok(actual) if actual == expected => result.report_ok(&format!(
                "{label}.chain_type_manager_implementation.isZKsyncOS() = {actual} matches artifact flavor"
            )),
            Ok(actual) => result.report_error(&format!(
                "{label}.chain_type_manager_implementation.isZKsyncOS() = {actual} disagrees with artifact flavor (expected {expected})"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.chain_type_manager_implementation.isZKsyncOS(): {err}"
            )),
        }
    }
    Ok(())
}

/// Stage-1 `MessageRoot.initializeL1V33Upgrade()` iterates
/// `Bridgehub.getAllZKChainChainIDs()` and `require`s every chain to have
/// `settlementLayer(chainId) == block.chainid`. Failing that on execution
/// would revert the governance proposal after signers approve it, so PUVT
/// pre-flights the same iteration at the review block.
///
/// `L1MessageRootStageSepolia` skips chain
/// `STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID` (270) because it's still
/// settling on the legacy stage Gateway at v33 upgrade time; PUVT applies
/// the same skip when `is_stage` is set.
async fn verify_v33_chain_settlement_layers(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) {
    let provider = verifiers.network_verifier.get_l1_provider();
    let bridgehub = BridgehubContract::new(verifiers.bridgehub_address, provider.clone());
    let expected_l1 = U256::from(verifiers.expected_l1_chain_id);

    let chain_ids = match bridgehub.getAllZKChainChainIDs().call().await {
        Ok(ids) => ids,
        Err(err) => {
            result.report_error(&format!(
                "Failed to call Bridgehub.getAllZKChainChainIDs() for settlementLayer pre-flight: {err}"
            ));
            return;
        }
    };

    for chain_id in chain_ids {
        if verifiers.env.is_stage()
            && chain_id == U256::from(STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID)
        {
            result.report_ok(&format!(
                "Skipping settlementLayer check for stage chain {chain_id} (L1MessageRootStageSepolia exception)"
            ));
            continue;
        }
        match bridgehub.settlementLayer(chain_id).call().await {
            Ok(sl) if sl == expected_l1 => result.report_ok(&format!(
                "Bridgehub.settlementLayer({chain_id}) == L1 ({expected_l1})"
            )),
            Ok(sl) => result.report_error(&format!(
                "Bridgehub.settlementLayer({chain_id}) mismatch: expected L1 {expected_l1}, got {sl}. Stage-1 MessageRoot.initializeL1V33Upgrade() would revert."
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call Bridgehub.settlementLayer({chain_id}): {err}"
            )),
        }
    }
}
