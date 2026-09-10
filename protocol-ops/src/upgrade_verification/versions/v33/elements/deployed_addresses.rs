use anyhow::{Context, Result};

use crate::upgrade_verification::{
    artifacts::{
        required_address_in_value as required_address, CtmArtifact, CtmFlavor,
        EcosystemUpgradeArtifact,
    },
    constants::L2_INTEROP_CENTER_ADDR,
    verifiers::{VerificationResult, Verifiers},
    versions::v33::{
        utils::network_verifier::{Bridgehub as BridgehubContract, L1AssetRouter},
        MAX_NUMBER_OF_ZK_CHAINS,
    },
};

use alloy::{
    hex::{self, FromHex},
    primitives::{Address, FixedBytes, U256},
    sol_types::{SolCall, SolConstructor},
};
use serde::Deserialize;

const GOVERNANCE_TIMER_MAX_ADDITIONAL_DELAY_SECONDS: u64 = 14 * 24 * 60 * 60;
const EXPECTED_GUARDIANS_MEMBER_COUNT: usize = 8;
/// `SecurityCouncil.sol` requires exactly this many members. The live council
/// carries more (12 on stage), so the redeploy copies the first 8 — see
/// `DeployPUHAndGuardians.s.sol::_readFirstMembers`.
const EXPECTED_SECURITY_COUNCIL_MEMBER_COUNT: usize = 8;
const ZK_GOVERNANCE_PUH_FILE: &str = "l1-contracts/ProtocolUpgradeHandler";
/// Zeroed-delay handler deployed on every non-mainnet ecosystem (stage/testnet).
const ZK_GOVERNANCE_TESTNET_PUH_FILE: &str = "l1-contracts/TestnetProtocolUpgradeHandler";
const ZK_GOVERNANCE_GUARDIANS_FILE: &str = "l1-contracts/Guardians";
const ZK_GOVERNANCE_SECURITY_COUNCIL_FILE: &str = "l1-contracts/SecurityCouncil";
const ZK_GOVERNANCE_EMERGENCY_BOARD_FILE: &str = "l1-contracts/EmergencyUpgradeBoard";

/// Expected constructor signatures for every contract deployed by
/// `CoreUpgrade_v33` (i.e. `verify_core_provenance`).
///
/// These declarations exist only to drive `abi_encode` for the expected
/// constructor-args byte slice; they are NOT used as RPC clients. The
/// signatures must match the corresponding Solidity contract under
/// `l1-contracts/contracts/core` / `l1-contracts/contracts/bridge`.
mod core_signatures {
    alloy::sol! {
        contract V33L1Bridgehub {
            constructor(address _owner, uint256 _maxNumberOfZKChains);
        }
        contract V33L1NativeTokenVault {
            constructor(address _wethToken, address _assetRouter, address _l1Nullifier);
        }
        contract V33L1AssetRouter {
            constructor(
                address _l1WethToken,
                address _bridgehub,
                address _l1Nullifier,
                uint256 _eraChainId,
                address _eraDiamondProxy
            );
        }
        contract V33L1Nullifier {
            constructor(address _bridgehub, address _messageRoot);
        }
        contract V33L1MessageRoot {
            constructor(address _bridgehub, uint256 _eraGatewayChainId, address _chainAssetHandler);
        }
        contract V33L1ChainAssetHandler {
            constructor(address _owner, address _bridgehub);
        }
        contract V33CTMDeploymentTracker {
            constructor(address _bridgehub, address _l1AssetRouter);
        }
        contract V33ChainRegistrationSender {
            constructor(address _bridgehub);
            function initialize(address _owner);
        }
        contract V33L1InteropHandler {
            constructor(address _messageRoot, address _l1AssetRouter);
            function initialize(address _owner);
        }
    }
}

/// Expected constructor signatures for every contract deployed by
/// `CTMUpgrade_v33` (i.e. `verify_ctm_provenance` and
/// `verify_ctm_base_provenance`).
///
/// `V33ChainTypeManager._interopCenter` is intentionally the L2 built-in
/// `INTEROP_CENTER` address — the contract stores it in an L1-side
/// `immutable` but uses it only when constructing L2-aliased messages
/// (see `ChainTypeManagerBase.sol`). Pass `L2_INTEROP_CENTER_ADDR` here.
mod ctm_signatures {
    alloy::sol! {
        contract V33AdminFacet {
            constructor(uint256 _l1ChainId, address _rollupDAManager);
        }
        contract V33ExecutorFacet {
            constructor();
        }
        contract V33CommitterFacet {
            constructor(uint256 _l1ChainId);
        }
        contract V33MailboxFacet {
            constructor(
                uint256 _l1ChainId,
                address _chainAssetHandler,
                address _eip7702Checker,
                bool _isTestnet
            );
        }
        contract V33MigratorFacet {
            constructor(uint256 _l1ChainId, bool _isTestnet);
        }
        contract V33ChainTypeManager {
            constructor(
                address _bridgehub,
                address _interopCenter,
                address _l1BytecodesSupplier,
                address _permissionlessValidator
            );
        }
        contract V33DualVerifier {
            constructor(address _fflonkVerifier, address _plonkVerifier);
        }
        contract V33ZKsyncOSVerifier {
            constructor(address _plonkVerifier);
        }
        contract V33GovernanceUpgradeTimer {
            constructor(
                uint256 _initialDelay,
                uint256 _maxAdditionalDelay,
                address _timerGovernance,
                address _initialOwner
            );
        }
        contract V33UpgradeStageValidator {
            constructor(address chainTypeManager, uint256 newProtocolVersion);
        }
        contract V33ValidatorTimelock {
            constructor(address _bridgehubAddr);
        }
        contract V33PermissionlessValidator {
            function initialize();
        }
        contract V33BytecodesSupplier {
            function initialize();
        }
    }
}

/// Expected constructor signatures for zk-governance contracts deployed by
/// `DeployPUHAndGuardians.s.sol`, plus read-only views used to reconstruct
/// the exact constructor inputs from the live pre-upgrade PUH state.
mod governance_signatures {
    alloy::sol! {
        contract V33ProtocolUpgradeHandler {
            constructor(
                address _l2ProtocolGovernor,
                address _eraChainTypeManager,
                address _zksyncOSChainTypeManager,
                address _bridgeHub,
                address _l1Nullifier,
                address _l1AssetRouter,
                address _l1NativeTokenVault,
                address _chainAssetHandler,
                uint256 _eraChainId
            );
        }

        contract V33Guardians {
            constructor(
                address _protocolUpgradeHandler,
                address _bridgeHub,
                uint256 _eraChainId,
                address[] _members
            );
        }

        contract V33SecurityCouncil {
            constructor(address _protocolUpgradeHandler, address[] _members);
        }

        contract V33EmergencyUpgradeBoard {
            constructor(
                address _protocolUpgradeHandler,
                address _securityCouncil,
                address _guardians,
                address _zkFoundation
            );
        }

        #[sol(rpc)]
        contract ProtocolUpgradeHandlerView {
            function L2_PROTOCOL_GOVERNOR() external view returns (address);
            function CHAIN_TYPE_MANAGER() external view returns (address);
            function BRIDGE_HUB() external view returns (address);
            function L1_NULLIFIER() external view returns (address);
            function L1_ASSET_ROUTER() external view returns (address);
            function L1_NATIVE_TOKEN_VAULT() external view returns (address);
            function guardians() external view returns (address);
            function securityCouncil() external view returns (address);
            function emergencyUpgradeBoard() external view returns (address);
        }

        #[sol(rpc)]
        contract GuardiansMembersView {
            function members(uint256 _index) external view returns (address);
        }

        #[sol(rpc)]
        contract EmergencyUpgradeBoardView {
            function ZK_FOUNDATION_SAFE() external view returns (address);
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

/// Deployment provenance.
///
/// For every named v33 implementation that the prepare scripts deploy via
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
/// legacy `UpgradeOutput` into a single v33 TOML reader. The current
/// commit keeps both side-by-side; Phase 6 reuses only the create2
/// machinery from `NetworkVerifier` (which does not depend on
/// `UpgradeOutput`) so the unification can land independently.
pub(crate) async fn verify_v33_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    era_chain_id: u64,
    message_root_era_gateway_chain_id: u64,
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
    // Zero is a legitimate value here, not a failure. `DefaultCoreUpgrade` sets
    // `config.eraDiamondProxyAddress = bridgehub.getZKChain(assetRouter.ERA_CHAIN_ID())` and
    // embeds whatever comes back into the L1AssetRouter / L1Nullifier constructors. On an
    // ecosystem whose `ERA_CHAIN_ID` names no registered chain that is address(0) — testnet's
    // deployed L1AssetRouter carries exactly that — so provenance must compare against zero
    // rather than refuse to run.
    if era_diamond_proxy == Address::ZERO {
        result.print_info(&format!(
            "Bridgehub.getZKChain({era_chain_id}) is address(0); verifying constructor args \
             against a zero Era diamond"
        ));
    }

    let governance = bridgehub
        .owner()
        .call()
        .await
        .context("calling Bridgehub.owner() for v33 provenance")?;

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
        message_root_era_gateway_chain_id,
        result,
        core_context,
    )
    .await?;

    for ctm in &artifact.ctms {
        verify_ctm_provenance(artifact, ctm, verifiers, l1_chain_id, result, core_context).await?;
    }

    // Whether a new zk-governance set was deployed is a property of the *release*, not of the
    // env's governance shape. v33 ships none, so its artifact carries no `[zk_governance]` table
    // and there is nothing to trace provenance for — even though the handler is proxy-admin'd.
    let governance_admin = verifiers.network_verifier.get_proxy_admin(governance).await;
    if governance_admin != Address::ZERO && artifact.zk_governance.is_some() {
        verify_zk_governance_provenance(artifact, verifiers, result).await?;
    }

    Ok(())
}

async fn verify_zk_governance_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    use governance_signatures::*;
    result.print_info("-- zk-governance deployment provenance --");

    let zk_governance = artifact.zk_governance.as_ref().context(
        "zk-governance v33 artifact is missing required top-level [zk_governance] table",
    )?;

    let provider = verifiers.network_verifier.get_l1_provider();
    let current_puh_addr = verifiers.bridgehub_owner;
    let current_puh = ProtocolUpgradeHandlerView::new(current_puh_addr, provider.clone());

    let zksync_os_ctm = artifact
        .ctms
        .iter()
        .find(|ctm| ctm.flavor == CtmFlavor::ZksyncOs)
        .context("zk-governance provenance requires a [ctms.zksync_os] section")?;
    let zksync_os_ctm_proxy = required_address(
        &zksync_os_ctm.value,
        "ctms.zksync_os",
        &["state_transition", "chain_type_manager_proxy"],
    )?;
    let chain_asset_handler = required_address(
        &artifact.core,
        "core",
        &[
            "upgrade_addresses",
            "bridgehub",
            "chain_asset_handler_proxy_addr",
        ],
    )?;

    let l2_protocol_governor = current_puh
        .L2_PROTOCOL_GOVERNOR()
        .call()
        .await
        .context("calling current PUH.L2_PROTOCOL_GOVERNOR() for zk-governance provenance")?;
    let era_ctm = current_puh
        .CHAIN_TYPE_MANAGER()
        .call()
        .await
        .context("calling current PUH.CHAIN_TYPE_MANAGER() for zk-governance provenance")?;
    let bridgehub = current_puh
        .BRIDGE_HUB()
        .call()
        .await
        .context("calling current PUH.BRIDGE_HUB() for zk-governance provenance")?;
    let l1_nullifier = current_puh
        .L1_NULLIFIER()
        .call()
        .await
        .context("calling current PUH.L1_NULLIFIER() for zk-governance provenance")?;
    let l1_asset_router = current_puh
        .L1_ASSET_ROUTER()
        .call()
        .await
        .context("calling current PUH.L1_ASSET_ROUTER() for zk-governance provenance")?;
    let l1_native_token_vault = current_puh
        .L1_NATIVE_TOKEN_VAULT()
        .call()
        .await
        .context("calling current PUH.L1_NATIVE_TOKEN_VAULT() for zk-governance provenance")?;

    let old_guardians = current_puh
        .guardians()
        .call()
        .await
        .context("calling current PUH.guardians() for zk-governance provenance")?;
    let guardians_members = read_guardians_members(verifiers, old_guardians).await?;

    let old_security_council = current_puh
        .securityCouncil()
        .call()
        .await
        .context("calling current PUH.securityCouncil() for zk-governance provenance")?;
    let security_council_members =
        read_multisig_members(verifiers, old_security_council, "SecurityCouncil").await?;
    // DeployPUHAndGuardians redeploys the SecurityCouncil with the first
    // EXPECTED_SECURITY_COUNCIL_MEMBER_COUNT members of the current council
    // (SecurityCouncil.sol enforces exactly that many). Mirror that truncation
    // so the expected ctor args match the on-chain deployment.
    anyhow::ensure!(
        security_council_members.len() >= EXPECTED_SECURITY_COUNCIL_MEMBER_COUNT,
        "current SecurityCouncil at {old_security_council} has {} members, fewer than the {EXPECTED_SECURITY_COUNCIL_MEMBER_COUNT} the redeploy requires",
        security_council_members.len()
    );
    let security_council_members =
        security_council_members[..EXPECTED_SECURITY_COUNCIL_MEMBER_COUNT].to_vec();

    let old_emergency_board = current_puh
        .emergencyUpgradeBoard()
        .call()
        .await
        .context("calling current PUH.emergencyUpgradeBoard() for zk-governance provenance")?;
    let zk_foundation_safe = EmergencyUpgradeBoardView::new(old_emergency_board, provider.clone())
        .ZK_FOUNDATION_SAFE()
        .call()
        .await
        .context("calling current EmergencyUpgradeBoard.ZK_FOUNDATION_SAFE() for provenance")?;

    // On every non-mainnet ecosystem the redeploy uses the zeroed-delay
    // `TestnetProtocolUpgradeHandler`; mainnet uses the real handler. This
    // mirrors `DeployPUHAndGuardians.s.sol`'s `USE_TESTNET_PUH` selection.
    let puh_file = if verifiers.env.is_mainnet() {
        ZK_GOVERNANCE_PUH_FILE
    } else {
        ZK_GOVERNANCE_TESTNET_PUH_FILE
    };

    let puh_ctor_args = V33ProtocolUpgradeHandler::constructorCall::new((
        l2_protocol_governor,
        era_ctm,
        zksync_os_ctm_proxy,
        bridgehub,
        l1_nullifier,
        l1_asset_router,
        l1_native_token_vault,
        chain_asset_handler,
        U256::from(verifiers.era_chain_id),
    ))
    .abi_encode();
    result.expect_create2_params(
        verifiers,
        &zk_governance.new_puh_impl,
        puh_ctor_args,
        puh_file,
    );

    let guardians_ctor_args = V33Guardians::constructorCall::new((
        current_puh_addr,
        bridgehub,
        U256::from(verifiers.era_chain_id),
        guardians_members,
    ))
    .abi_encode();
    result.expect_create2_params(
        verifiers,
        &zk_governance.new_guardians,
        guardians_ctor_args,
        ZK_GOVERNANCE_GUARDIANS_FILE,
    );

    let security_council_ctor_args =
        V33SecurityCouncil::constructorCall::new((current_puh_addr, security_council_members))
            .abi_encode();
    result.expect_create2_params(
        verifiers,
        &zk_governance.new_security_council,
        security_council_ctor_args,
        ZK_GOVERNANCE_SECURITY_COUNCIL_FILE,
    );

    // The new board embeds the *new* SecurityCouncil + Guardians (so it never
    // dangles against the stale set) and preserves the existing ZK Foundation safe.
    let emergency_board_ctor_args = V33EmergencyUpgradeBoard::constructorCall::new((
        current_puh_addr,
        zk_governance.new_security_council,
        zk_governance.new_guardians,
        zk_foundation_safe,
    ))
    .abi_encode();
    result.expect_create2_params(
        verifiers,
        &zk_governance.new_emergency_upgrade_board,
        emergency_board_ctor_args,
        ZK_GOVERNANCE_EMERGENCY_BOARD_FILE,
    );

    Ok(())
}

/// Reads a `Multisig`'s member list (length at storage slot 0, then
/// `members(i)`). Generic over Guardians / SecurityCouncil; unlike
/// [`read_guardians_members`] it does not assert a fixed member count.
async fn read_multisig_members(
    verifiers: &Verifiers,
    multisig_addr: Address,
    label: &str,
) -> Result<Vec<Address>> {
    use governance_signatures::GuardiansMembersView;

    let raw_len = verifiers
        .network_verifier
        .storage_at(&multisig_addr, &FixedBytes::<32>::ZERO)
        .await;
    let members_len = U256::from_be_slice(raw_len.as_slice());
    anyhow::ensure!(
        members_len != U256::ZERO,
        "current {label} at {multisig_addr} has no members"
    );
    let members_len = usize::try_from(members_len)
        .with_context(|| format!("{label} member count {members_len} overflows usize"))?;

    let multisig =
        GuardiansMembersView::new(multisig_addr, verifiers.network_verifier.get_l1_provider());
    let mut members = Vec::with_capacity(members_len);
    for index in 0..members_len {
        let member = multisig
            .members(U256::from(index))
            .call()
            .await
            .with_context(|| format!("calling current {label}.members({index}) for provenance"))?;
        anyhow::ensure!(
            member != Address::ZERO,
            "current {label}.members({index}) returned address(0)"
        );
        members.push(member);
    }
    Ok(members)
}

async fn read_guardians_members(
    verifiers: &Verifiers,
    guardians_addr: Address,
) -> Result<Vec<Address>> {
    use governance_signatures::GuardiansMembersView;

    let raw_len = verifiers
        .network_verifier
        .storage_at(&guardians_addr, &FixedBytes::<32>::ZERO)
        .await;
    let members_len = U256::from_be_slice(raw_len.as_slice());
    anyhow::ensure!(
        members_len == U256::from(EXPECTED_GUARDIANS_MEMBER_COUNT),
        "current Guardians at {guardians_addr} must have exactly {EXPECTED_GUARDIANS_MEMBER_COUNT} members, got {members_len}"
    );

    let guardians =
        GuardiansMembersView::new(guardians_addr, verifiers.network_verifier.get_l1_provider());
    let mut members = Vec::with_capacity(EXPECTED_GUARDIANS_MEMBER_COUNT);
    for index in 0..EXPECTED_GUARDIANS_MEMBER_COUNT {
        let member = guardians
            .members(U256::from(index))
            .call()
            .await
            .with_context(|| {
                format!("calling current Guardians.members({index}) for zk-governance provenance")
            })?;
        anyhow::ensure!(
            member != Address::ZERO,
            "current Guardians.members({index}) returned address(0)"
        );
        members.push(member);
    }
    Ok(members)
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
    message_root_era_gateway_chain_id: u64,
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
    let asset_router_impl = in_bridges("l1_asset_router_implementation_addr")?;
    let nullifier_impl = in_bridges("l1_nullifier_implementation_addr")?;
    let bridgehub_impl = in_bh("bridgehub_implementation_addr")?;
    let crs_impl = in_bh("chain_registration_sender_implementation_addr")?;
    let crs_proxy = in_bh("chain_registration_sender_proxy_addr")?;
    let interop_handler_impl = in_bridges("l1_interop_handler_implementation_addr")?;
    let interop_handler_proxy = in_bridges("l1_interop_handler_proxy_addr")?;
    let core_proxy_admin = required_address(
        core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    // Every env deploys the canonical `L1MessageRoot`: the stage-sepolia variant (which skipped
    // chain 270's settlement check during the v33 rollout) was removed together with the v33
    // stage-1 initializer.
    let message_root_file = "l1-contracts/L1MessageRoot";

    // ChainRegistrationSender impl args are reused for the TUPP impl check below.
    let crs_ctor_args =
        V33ChainRegistrationSender::constructorCall::new((context.bridgehub_addr,)).abi_encode();

    // Single dispatch table: (address, encoded ctor args, expected file).
    let checks: Vec<(Address, Vec<u8>, &str)> = vec![
        // L1ChainAssetHandler impl(_owner=governance, _bridgehub).
        (
            chain_asset_handler_impl,
            V33L1ChainAssetHandler::constructorCall::new((
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
            V33L1MessageRoot::constructorCall::new((
                context.bridgehub_addr,
                U256::from(message_root_era_gateway_chain_id),
                chain_asset_handler_proxy,
            ))
            .abi_encode(),
            message_root_file,
        ),
        // L1InteropHandler impl(messageRoot, assetRouter). Deployed on both
        // branches of `deployVersionSpecificEcosystemContractsL1`; only the
        // proxy is conditional (checked below).
        (
            interop_handler_impl,
            V33L1InteropHandler::constructorCall::new((
                message_root_proxy,
                context.asset_router_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1InteropHandler",
        ),
        // L1NativeTokenVault impl(weth, assetRouter, nullifier).
        (
            ntv_impl,
            V33L1NativeTokenVault::constructorCall::new((
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
            V33CTMDeploymentTracker::constructorCall::new((
                context.bridgehub_addr,
                context.asset_router_proxy,
            ))
            .abi_encode(),
            "l1-contracts/CTMDeploymentTracker",
        ),
        // L1AssetRouter impl(weth, bridgehub, nullifier, eraChainId, eraDiamondProxy).
        (
            asset_router_impl,
            V33L1AssetRouter::constructorCall::new((
                context.weth,
                context.bridgehub_addr,
                context.nullifier,
                U256::from(era_chain_id),
                context.era_diamond_proxy,
            ))
            .abi_encode(),
            "l1-contracts/L1AssetRouter",
        ),
        // L1Nullifier impl(bridgehub, messageRoot).
        (
            nullifier_impl,
            V33L1Nullifier::constructorCall::new((context.bridgehub_addr, message_root_proxy))
                .abi_encode(),
            "l1-contracts/L1Nullifier",
        ),
        // L1Bridgehub impl(_owner=governance, _maxNumberOfZKChains).
        (
            bridgehub_impl,
            V33L1Bridgehub::constructorCall::new((
                context.governance,
                U256::from(MAX_NUMBER_OF_ZK_CHAINS),
            ))
            .abi_encode(),
            "l1-contracts/L1Bridgehub",
        ),
        // ChainRegistrationSender impl(bridgehub).
        // Args reused below for the TUPP impl check.
        (
            crs_impl,
            crs_ctor_args.clone(),
            "l1-contracts/ChainRegistrationSender",
        ),
    ];
    for (addr, args, file) in &checks {
        result.expect_create2_params(verifiers, addr, args.as_slice(), file);
    }

    // Like the two CTM-side kept proxies, the ChainRegistrationSender proxy
    // pre-dates this release; only its implementation (checked above, in
    // `checks`) is redeployed here.
    result
        .expect_preexisting_proxy(
            verifiers,
            &crs_proxy,
            core_proxy_admin,
            "ChainRegistrationSender",
        )
        .await;

    // The interop handler proxy is deployed only for an ecosystem that does
    // not already have one. When it is deployed here it is initialized
    // straight to governance — no deployer-then-transfer step — so the TUPP
    // init payload must name the owner, not the deployer.
    if verifiers
        .network_verifier
        .create2_known_bytecodes
        .contains_key(&interop_handler_proxy)
    {
        result
            .expect_create2_params_proxy_with_bytecode(
                verifiers,
                &interop_handler_proxy,
                V33L1InteropHandler::initializeCall::new((context.governance,)).abi_encode(),
                core_proxy_admin,
                V33L1InteropHandler::constructorCall::new((
                    message_root_proxy,
                    context.asset_router_proxy,
                ))
                .abi_encode(),
                "l1-contracts/L1InteropHandler",
            )
            .await;
    } else {
        result
            .expect_preexisting_proxy(
                verifiers,
                &interop_handler_proxy,
                core_proxy_admin,
                "L1InteropHandler",
            )
            .await;
    }

    Ok(())
}

async fn verify_ctm_provenance(
    artifact: &EcosystemUpgradeArtifact,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    l1_chain_id: u64,
    result: &mut VerificationResult,
    context: CoreProvenanceContext,
) -> Result<()> {
    use ctm_signatures::*;

    verify_ctm_base_provenance(ctm, verifiers, l1_chain_id, result)?;

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
        CtmFlavor::ZksyncOs => "l1-contracts/ZKsyncOSChainTypeManager",
    };

    // Single dispatch table: (address, encoded ctor args, expected file).
    let checks: Vec<(Address, Vec<u8>, &str)> = vec![
        // CommitterFacet(_l1ChainId).
        (
            committer,
            V33CommitterFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/CommitterFacet",
        ),
        // MailboxFacet(l1ChainId, chainAssetHandler, eip7702Checker, isTestnet).
        (
            mailbox,
            V33MailboxFacet::constructorCall::new((
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
            V33MigratorFacet::constructorCall::new((
                U256::from(l1_chain_id),
                ctm.contracts_config.is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MigratorFacet",
        ),
        // GovernanceUpgradeTimer(initialDelay, maxAdditionalDelay, timerGovernance, initialOwner).
        (
            timer,
            V33GovernanceUpgradeTimer::constructorCall::new((
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
            V33UpgradeStageValidator::constructorCall::new((
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
            V33ChainTypeManager::constructorCall::new((
                bridgehub_addr,
                L2_INTEROP_CENTER_ADDR,
                bytecodes_supplier,
                permissionless_validator,
            ))
            .abi_encode(),
            ctm_file,
        ),
        // Validator impl(bridgehub). Deployed once per CTM by `CTMUpgrade_v33`;
        // stage-1 governance swaps this behind the per-CTM ValidatorTimelock
        // proxy. v33 deploys `MultisigCommitter` (a superset of ValidatorTimelock
        // with the same `(bridgehub)` constructor) as the default validator impl,
        // so the upgrade does not downgrade proxies already running a
        // MultisigCommitter.
        (
            validator_timelock_impl,
            V33ValidatorTimelock::constructorCall::new((bridgehub_addr,)).abi_encode(),
            "l1-contracts/MultisigCommitter",
        ),
    ];
    for (addr, args, file) in &checks {
        result.expect_create2_params(verifiers, addr, args.as_slice(), file);
    }

    // BytecodesSupplier and PermissionlessValidator are kept across the
    // release: v33 swaps their implementations but reuses the existing
    // proxies, so neither proxy appears in this upgrade's CREATE2
    // deployments. The stage-1 payload pass checks that the governance calls
    // point each one at an implementation deployed here.
    for (proxy, label) in [
        (&bytecodes_supplier, "BytecodesSupplier"),
        (&permissionless_validator, "PermissionlessValidator"),
    ] {
        result
            .expect_preexisting_proxy(verifiers, proxy, transparent_proxy_admin, label)
            .await;
    }

    Ok(())
}

/// Per-CTM, per-flavor provenance for the contracts that ship one copy per
/// CTM (verifiers, DiamondInit, default_upgrade, genesis_upgrade, getters/
/// executor/admin facets, ServerNotifier, EIP7702Checker). The v33 upgrade
/// deploys these once for Era and once for ZKsyncOS, so verification
/// iterates per CTM and uses each CTM's own `flavor`.
///
/// All required addresses come from the CTM's own `[ctms.<flavor>]`
/// section via `required_address`.
fn verify_ctm_base_provenance(
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
    let (verifier_plonk_file, verifier_fflonk_file, main_verifier_file, testnet_verifier_file) =
        match ctm.flavor {
            CtmFlavor::ZksyncOs => (
                "l1-contracts/ZKsyncOSVerifierPlonk",
                None,
                "l1-contracts/ZKsyncOSVerifier",
                "l1-contracts/ZKsyncOSTestnetVerifier",
            ),
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
        // {Era,ZKsyncOS}VerifierPlonk() — no ctor args.
        (
            &["state_transition", "verifier_plonk_addr"],
            verifier_plonk_file,
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

    if let Some(verifier_fflonk_file) = verifier_fflonk_file {
        let verifier_fflonk = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "verifier_fflonk_addr"],
        )?;
        result.expect_create2_params(
            verifiers,
            &verifier_fflonk,
            Vec::<u8>::new(),
            verifier_fflonk_file,
        );
    }

    // Only ZKsync OS chains can be upgraded onto this release, so the per-chain upgrade contract
    // and its registry exist for ZKsync OS CTMs only.
    if is_zksync_os {
        // PriorityOpLowerBound() — no ctor args; the registry the per-chain upgrade embeds.
        let priority_op_lower_bound = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "priority_op_lower_bound_addr"],
        )?;
        result.expect_create2_params(
            verifiers,
            &priority_op_lower_bound,
            Vec::<u8>::new(),
            "l1-contracts/PriorityOpLowerBound",
        );

        // V32UpgradeZKsyncOS(IPriorityOpLowerBound) — the per-chain upgrade contract embeds the
        // registry address as its single constructor argument, encoded as a left-padded 32-byte word.
        let default_upgrade = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "default_upgrade_addr"],
        )?;
        let mut default_upgrade_ctor = vec![0u8; 32];
        default_upgrade_ctor[12..].copy_from_slice(priority_op_lower_bound.as_slice());
        result.expect_create2_params(
            verifiers,
            &default_upgrade,
            default_upgrade_ctor,
            "l1-contracts/V32UpgradeZKsyncOS",
        );

        // DefaultUpgradeZKsyncOS() — no ctor args. This is the contract the CTM
        // *stores* as its `defaultUpgrade`, so every later patch upgrade
        // delegates through it. Its provenance therefore matters as much as the
        // one-shot cut's: without this, `setDefaultUpgrade` could name any live
        // address and stage-1 verification would still pass, because the only
        // other check compares it to the same artifact field.
        let ctm_stored_default_upgrade = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "ctm_stored_default_upgrade_addr"],
        )?;
        result.expect_create2_params(
            verifiers,
            &ctm_stored_default_upgrade,
            Vec::<u8>::new(),
            "l1-contracts/DefaultUpgradeZKsyncOS",
        );
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

    // ExecutorFacet() — file is shared across flavors, but the address is
    // per-CTM.
    let executor = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "executor_facet_addr"],
    )?;
    result.expect_create2_params(
        verifiers,
        &executor,
        V33ExecutorFacet::constructorCall::new(()).abi_encode(),
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
        V33AdminFacet::constructorCall::new((U256::from(l1_chain_id), rollup_da_manager))
            .abi_encode(),
        "l1-contracts/AdminFacet",
    );

    // Main verifier / *TestnetVerifier. Era receives both verifier implementations;
    // ZKsync OS receives only PLONK.
    //
    let verifier = required_address(&ctm.value, &scope, &["state_transition", "verifier_addr"])?;
    let plonk = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "verifier_plonk_addr"],
    )?;
    let verifier_file = if !verifiers.env.is_mainnet() {
        testnet_verifier_file
    } else {
        main_verifier_file
    };
    let encoded = if is_zksync_os {
        V33ZKsyncOSVerifier::constructorCall::new((plonk,)).abi_encode()
    } else {
        let fflonk = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "verifier_fflonk_addr"],
        )?;
        V33DualVerifier::constructorCall::new((fflonk, plonk)).abi_encode()
    };
    result.expect_create2_params(verifiers, &verifier, encoded, verifier_file);

    Ok(())
}

fn parse_bytes32_hex(label: &str, value: &str) -> Result<FixedBytes<32>> {
    FixedBytes::<32>::from_hex(value)
        .with_context(|| format!("{label} must be a 0x-prefixed 32-byte hex string"))
}

fn parse_optional_bytes32_hex(label: &str, value: Option<&str>) -> Result<FixedBytes<32>> {
    match value {
        Some(value) => parse_bytes32_hex(label, value),
        None => Ok(FixedBytes::<32>::ZERO),
    }
}

fn zksync_os_genesis_batch_commitment() -> FixedBytes<32> {
    FixedBytes::<32>::from(U256::from(1).to_be_bytes::<32>())
}

fn hex_bytes(label: &str, value: &str) -> Result<Vec<u8>> {
    hex::decode(value.trim_start_matches("0x"))
        .with_context(|| format!("{label} must be 0x-prefixed hex"))
}
