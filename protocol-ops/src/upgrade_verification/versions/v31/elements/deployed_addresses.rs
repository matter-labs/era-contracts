use anyhow::{Context, Result};

use crate::upgrade_verification::{
    artifacts::{
        required_address_in_value as required_address, CtmArtifact, CtmFlavor,
        EcosystemUpgradeArtifact,
    },
    constants::{L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_CENTER_ADDR},
    verifiers::{VerificationResult, Verifiers},
    versions::v31::{
        utils::{
            apply_l2_to_l1_alias,
            network_verifier::{Bridgehub as BridgehubContract, L1AssetRouter},
        },
        MAX_NUMBER_OF_ZK_CHAINS,
    },
};

use alloy::{
    hex::{self, FromHex},
    primitives::{Address, Bytes, FixedBytes, U256},
    sol_types::{SolCall, SolConstructor, SolValue},
};
use serde::Deserialize;

const GOVERNANCE_TIMER_MAX_ADDITIONAL_DELAY_SECONDS: u64 = 14 * 24 * 60 * 60;
const EXPECTED_GUARDIANS_MEMBER_COUNT: usize = 8;
const ZK_GOVERNANCE_PUH_FILE: &str = "l1-contracts/ProtocolUpgradeHandler";
/// Zeroed-delay handler deployed on every non-mainnet ecosystem (stage/testnet).
const ZK_GOVERNANCE_TESTNET_PUH_FILE: &str = "l1-contracts/TestnetProtocolUpgradeHandler";
const ZK_GOVERNANCE_GUARDIANS_FILE: &str = "l1-contracts/Guardians";
const ZK_GOVERNANCE_SECURITY_COUNCIL_FILE: &str = "l1-contracts/SecurityCouncil";
const ZK_GOVERNANCE_EMERGENCY_BOARD_FILE: &str = "l1-contracts/EmergencyUpgradeBoard";

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
            function initialize(address _owner);
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

/// Expected constructor signatures for the contracts that the new-Gateway
/// vote-preparation script sends to the Gateway via L1 priority txs.
mod gateway_signatures {
    alloy::sol! {
        #[derive(Debug)]
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
        struct InitializeDataNewChain {
            bytes32 l2BootloaderBytecodeHash;
            bytes32 l2DefaultAccountBytecodeHash;
            bytes32 l2EvmEmulatorBytecodeHash;
        }

        #[derive(Debug)]
        struct GatewayDADeployerConfig {
            bytes32 salt;
            address aliasedGovernanceAddress;
        }

        #[derive(Debug)]
        struct GatewayProxyAdminDeployerConfig {
            bytes32 salt;
            address aliasedGovernanceAddress;
        }

        #[derive(Debug)]
        struct GatewayValidatorTimelockDeployerConfig {
            bytes32 salt;
            address aliasedGovernanceAddress;
            address chainTypeManagerProxyAdmin;
        }

        #[derive(Debug)]
        struct GatewayVerifiersDeployerConfig {
            bytes32 salt;
            address aliasedGovernanceAddress;
            bool testnetVerifier;
            bool isZKsyncOS;
        }

        #[derive(Debug)]
        struct GatewayCTMDeployerConfig {
            address aliasedGovernanceAddress;
            bytes32 salt;
            uint256 eraChainId;
            uint256 l1ChainId;
            bool testnetVerifier;
            bool isZKsyncOS;
            bytes4[] adminSelectors;
            bytes4[] executorSelectors;
            bytes4[] mailboxSelectors;
            bytes4[] gettersSelectors;
            bytes4[] migratorSelectors;
            bytes4[] committerSelectors;
            bytes32 bootloaderHash;
            bytes32 defaultAccountHash;
            bytes32 evmEmulatorHash;
            bytes32 genesisRoot;
            uint256 genesisRollupLeafIndex;
            bytes32 genesisBatchCommitment;
            bytes forceDeploymentsData;
            uint256 protocolVersion;
        }

        #[derive(Debug)]
        struct Facets {
            address adminFacet;
            address mailboxFacet;
            address executorFacet;
            address gettersFacet;
            address migratorFacet;
            address committerFacet;
            address diamondInit;
        }

        #[derive(Debug)]
        struct GatewayCTMFinalConfig {
            GatewayCTMDeployerConfig baseConfig;
            address chainTypeManagerProxyAdmin;
            address validatorTimelockProxy;
            Facets facets;
            address genesisUpgrade;
            address verifier;
        }

        struct GatewayDADeployerResult {
            address rollupDAManager;
            address rollupSLDAValidator;
            address validiumDAValidator;
        }

        struct GatewayProxyAdminDeployerResult {
            address chainTypeManagerProxyAdmin;
        }

        struct GatewayValidatorTimelockDeployerResult {
            address validatorTimelockImplementation;
            address validatorTimelockProxy;
        }

        struct GatewayVerifiersDeployerResult {
            address verifierFflonk;
            address verifierPlonk;
            address verifier;
        }

        struct GatewayCTMFinalResult {
            address serverNotifierImplementation;
            address serverNotifierProxy;
            address chainTypeManagerImplementation;
            address chainTypeManagerProxy;
            bytes diamondCutData;
        }

        #[sol(rpc)]
        contract GatewayCTMDeployerDA {
            function getResult() external view returns (GatewayDADeployerResult result);
        }

        #[sol(rpc)]
        contract GatewayCTMDeployerProxyAdmin {
            function getResult() external view returns (GatewayProxyAdminDeployerResult result);
        }

        #[sol(rpc)]
        contract GatewayCTMDeployerValidatorTimelock {
            function getResult() external view returns (GatewayValidatorTimelockDeployerResult result);
        }

        #[sol(rpc)]
        contract GatewayCTMDeployerVerifiers {
            function getResult() external view returns (GatewayVerifiersDeployerResult result);
        }

        #[sol(rpc)]
        contract GatewayCTMDeployerCTM {
            function getResult() external view returns (GatewayCTMFinalResult result);
        }
    }
}

/// Expected constructor signatures for zk-governance contracts deployed by
/// `DeployPUHAndGuardians.s.sol`, plus read-only views used to reconstruct
/// the exact constructor inputs from the live pre-upgrade PUH state.
mod governance_signatures {
    alloy::sol! {
        contract V31ProtocolUpgradeHandler {
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

        contract V31Guardians {
            constructor(
                address _protocolUpgradeHandler,
                address _bridgeHub,
                uint256 _eraChainId,
                address[] _members
            );
        }

        contract V31SecurityCouncil {
            constructor(address _protocolUpgradeHandler, address[] _members);
        }

        contract V31EmergencyUpgradeBoard {
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

    verify_v31_new_gateway_ctm_provenance(artifact, verifiers, era_chain_id, l1_chain_id, result)
        .await?;

    let governance_admin = verifiers.network_verifier.get_proxy_admin(governance).await;
    if governance_admin != Address::ZERO {
        verify_puh_guardians_provenance(artifact, verifiers, result).await?;
    }

    Ok(())
}

async fn verify_puh_guardians_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    use governance_signatures::*;
    result.print_info("-- PUH/Guardians deployment provenance --");

    let puh_guardians = artifact
        .puh_guardians
        .as_ref()
        .context("PUH-governed v31 artifact is missing required top-level [puh_guardians] table")?;

    let provider = verifiers.network_verifier.get_l1_provider();
    let current_puh_addr = verifiers.bridgehub_owner;
    let current_puh = ProtocolUpgradeHandlerView::new(current_puh_addr, provider.clone());

    let zksync_os_ctm = artifact
        .ctms
        .iter()
        .find(|ctm| ctm.flavor == CtmFlavor::ZksyncOs)
        .context("PUH/Guardians provenance requires a [ctms.zksync_os] section")?;
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

    let puh_ctor_args = V31ProtocolUpgradeHandler::constructorCall::new((
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
        &puh_guardians.new_puh_impl,
        puh_ctor_args,
        puh_file,
    );

    let guardians_ctor_args = V31Guardians::constructorCall::new((
        current_puh_addr,
        bridgehub,
        U256::from(verifiers.era_chain_id),
        guardians_members,
    ))
    .abi_encode();
    result.expect_create2_params(
        verifiers,
        &puh_guardians.new_guardians,
        guardians_ctor_args,
        ZK_GOVERNANCE_GUARDIANS_FILE,
    );

    let security_council_ctor_args =
        V31SecurityCouncil::constructorCall::new((current_puh_addr, security_council_members))
            .abi_encode();
    result.expect_create2_params(
        verifiers,
        &puh_guardians.new_security_council,
        security_council_ctor_args,
        ZK_GOVERNANCE_SECURITY_COUNCIL_FILE,
    );

    // The new board embeds the *new* SecurityCouncil + Guardians (so it never
    // dangles against the stale set) and preserves the existing ZK Foundation safe.
    let emergency_board_ctor_args = V31EmergencyUpgradeBoard::constructorCall::new((
        current_puh_addr,
        puh_guardians.new_security_council,
        puh_guardians.new_guardians,
        zk_foundation_safe,
    ))
    .abi_encode();
    result.expect_create2_params(
        verifiers,
        &puh_guardians.new_emergency_upgrade_board,
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
    let crs_impl = in_bh("chain_registration_sender_implementation_addr")?;
    let crs_proxy = in_bh("chain_registration_sender_proxy_addr")?;
    let deployer = required_address(&artifact.misc, "misc", &["deployer_addr"])?;
    let core_proxy_admin = required_address(
        core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    // L1MessageRoot has a stage-sepolia variant with the same constructor
    // signature but different runtime bytecode. The choice is fixed by the
    // env: stage expects `L1MessageRootStageSepolia` (it skips chain 270 in
    // `_v31InitializeInner` because that chain is still settling on the
    // legacy stage Gateway at v31 upgrade time); testnet and mainnet expect
    // the canonical `L1MessageRoot`.
    let message_root_file = if verifiers.env.is_stage() {
        "l1-contracts/L1MessageRootStageSepolia"
    } else {
        "l1-contracts/L1MessageRoot"
    };

    // L1AssetTracker impl args are reused for the TUPP impl check below.
    let tracker_ctor_args = V31L1AssetTracker::constructorCall::new((
        context.bridgehub_addr,
        context.ntv_proxy,
        message_root_proxy,
    ))
    .abi_encode();

    // ChainRegistrationSender impl args are reused for the TUPP impl check below.
    let crs_ctor_args =
        V31ChainRegistrationSender::constructorCall::new((context.bridgehub_addr,)).abi_encode();

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

    // ChainRegistrationSender TransparentUpgradeableProxy(impl, proxyAdmin, initialize(deployer)).
    result
        .expect_create2_params_proxy_with_bytecode(
            verifiers,
            &crs_proxy,
            V31ChainRegistrationSender::initializeCall::new((deployer,)).abi_encode(),
            core_proxy_admin,
            crs_ctor_args,
            "l1-contracts/ChainRegistrationSender",
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
    // The choice is fixed by the env: mainnet expects `*DualVerifier`;
    // stage/testnet expect the `*TestnetVerifier` flavor instead.
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
    let verifier_file = if !verifiers.env.is_mainnet() {
        testnet_verifier_file
    } else {
        dual_verifier_file
    };
    let encoded = if is_zksync_os {
        let initial_owner = required_address(&artifact.misc, "misc", &["deployer_addr"])?;
        V31ZKsyncOSDualVerifier::constructorCall::new((fflonk, plonk, initial_owner)).abi_encode()
    } else {
        V31DualVerifier::constructorCall::new((fflonk, plonk)).abi_encode()
    };
    result.expect_create2_params(verifiers, &verifier, encoded, verifier_file);

    Ok(())
}

async fn verify_v31_new_gateway_ctm_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    era_chain_id: u64,
    l1_chain_id: u64,
    result: &mut VerificationResult,
) -> Result<()> {
    use ctm_signatures::*;
    use gateway_signatures::*;

    result.print_info("-- New Gateway CTM deployment provenance --");

    let Some(new_gateway) = artifact.new_gateway.as_ref() else {
        result.report_error("Missing [new_gateway] artifact block for Gateway CTM provenance");
        return Ok(());
    };
    let gw_scope = "new_gateway";
    let in_gst = |last: &str| {
        required_address(
            &new_gateway.value,
            gw_scope,
            &["gateway_state_transition", last],
        )
    };

    let source_ctm = source_ctm_for_new_gateway(artifact, verifiers)?;
    let is_zksync_os = matches!(source_ctm.flavor, CtmFlavor::ZksyncOs);
    let aliased_governance = apply_l2_to_l1_alias(verifiers.bridgehub_owner);
    let gateway_salt = verifiers.gateway_ctm_create2_salt;

    let admin = in_gst("admin_facet_addr")?;
    let committer = in_gst("committer_facet_addr")?;
    let ctm_impl = in_gst("chain_type_manager_implementation_addr")?;
    let ctm_proxy = in_gst("chain_type_manager_proxy_addr")?;
    let default_upgrade = in_gst("default_upgrade_addr")?;
    let diamond_init = in_gst("diamond_init_addr")?;
    let diamond_proxy = in_gst("diamond_proxy_addr")?;
    let executor = in_gst("executor_facet_addr")?;
    let genesis_upgrade = in_gst("genesis_upgrade_addr")?;
    let getters = in_gst("getters_facet_addr")?;
    let mailbox = in_gst("mailbox_facet_addr")?;
    let migrator = in_gst("migrator_facet_addr")?;
    let rollup_da_manager = in_gst("rollup_da_manager_addr")?;
    let server_notifier_impl = in_gst("server_notifier_implementation_addr")?;
    let server_notifier_proxy = in_gst("server_notifier_proxy_addr")?;
    let validator_timelock = in_gst("validator_timelock_addr")?;
    let verifier = in_gst("verifier_addr")?;
    let force_deployments_data = read_gateway_force_deployments_data(new_gateway)?;

    expect_zero_gateway_address(
        result,
        "new_gateway.gateway_state_transition.default_upgrade_addr",
        default_upgrade,
    );
    expect_zero_gateway_address(
        result,
        "new_gateway.gateway_state_transition.diamond_proxy_addr",
        diamond_proxy,
    );

    let (diamond_cut, diamond_cut_bytes) = decode_gateway_diamond_cut(new_gateway)?;
    if diamond_cut.facetCuts.len() != 6 {
        result.report_error(&format!(
            "new_gateway.diamond_cut_data must carry exactly 6 facet cuts, got {}",
            diamond_cut.facetCuts.len()
        ));
        return Ok(());
    }

    let admin_cut = &diamond_cut.facetCuts[0];
    let getters_cut = &diamond_cut.facetCuts[1];
    let mailbox_cut = &diamond_cut.facetCuts[2];
    let executor_cut = &diamond_cut.facetCuts[3];
    let migrator_cut = &diamond_cut.facetCuts[4];
    let committer_cut = &diamond_cut.facetCuts[5];

    expect_gateway_facet_cut(result, "admin", admin_cut, admin, false);
    expect_gateway_facet_cut(result, "getters", getters_cut, getters, false);
    expect_gateway_facet_cut(result, "mailbox", mailbox_cut, mailbox, true);
    expect_gateway_facet_cut(result, "executor", executor_cut, executor, true);
    expect_gateway_facet_cut(result, "migrator", migrator_cut, migrator, false);
    expect_gateway_facet_cut(result, "committer", committer_cut, committer, true);

    let initialize_data = InitializeDataNewChain::abi_decode(&diamond_cut.initCalldata)
        .context("decode new_gateway.diamond_cut_data.initCalldata as InitializeDataNewChain")?;
    let genesis_config = verifiers.genesis_config_for_ctm(source_ctm.flavor);
    let gw_provider = verifiers.network_verifier.get_gw_provider();

    // Direct Gateway L1->L2 CREATE2 deployments. These are present as raw
    // priority tx calldata and therefore can be checked by address.
    let mut diamond_init_args = vec![0u8; 32];
    if is_zksync_os {
        diamond_init_args[31] = 1;
    }
    let direct_checks: Vec<(Address, Vec<u8>, &str)> = vec![
        (
            admin,
            V31AdminFacet::constructorCall::new((U256::from(l1_chain_id), rollup_da_manager))
                .abi_encode(),
            "l1-contracts/AdminFacet",
        ),
        (
            mailbox,
            V31MailboxFacet::constructorCall::new((
                U256::from(era_chain_id),
                U256::from(l1_chain_id),
                L2_CHAIN_ASSET_HANDLER_ADDR,
                Address::ZERO,
                source_ctm.contracts_config.is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MailboxFacet",
        ),
        (
            executor,
            V31ExecutorFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/ExecutorFacet",
        ),
        (getters, Vec::new(), "l1-contracts/GettersFacet"),
        (
            migrator,
            V31MigratorFacet::constructorCall::new((
                U256::from(l1_chain_id),
                source_ctm.contracts_config.is_testnet,
            ))
            .abi_encode(),
            "l1-contracts/MigratorFacet",
        ),
        (
            committer,
            V31CommitterFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/CommitterFacet",
        ),
        (diamond_init, diamond_init_args, "l1-contracts/DiamondInit"),
        (genesis_upgrade, Vec::new(), "l1-contracts/L1GenesisUpgrade"),
    ];
    for (addr, args, file) in &direct_checks {
        result.expect_create2_params(verifiers, addr, args.as_slice(), file);
    }

    // Wrapper deployers. Their priority txs are the provenance boundary for
    // child contracts such as RollupDAManager, ValidatorTimelock,
    // ServerNotifier and the Gateway CTM proxy/implementation.
    let da_deployer = expect_create2_params_by_file(
        verifiers,
        result,
        "Gateway DA deployer",
        "l1-contracts/GatewayCTMDeployerDA",
        GatewayDADeployerConfig {
            salt: gateway_salt,
            aliasedGovernanceAddress: aliased_governance,
        }
        .abi_encode(),
    );
    if let Some(da_deployer) = da_deployer {
        let da_deployer_result = GatewayCTMDeployerDA::new(da_deployer, gw_provider.clone())
            .getResult()
            .call()
            .await
            .context("read GatewayCTMDeployerDA.getResult()")?;
        expect_gateway_deployer_address(
            result,
            "Gateway DA deployer RollupDAManager",
            rollup_da_manager,
            da_deployer_result.rollupDAManager,
        );
    }

    let proxy_admin_deployer = expect_create2_params_by_file(
        verifiers,
        result,
        "Gateway proxy-admin deployer",
        "l1-contracts/GatewayCTMDeployerProxyAdmin",
        GatewayProxyAdminDeployerConfig {
            salt: gateway_salt,
            aliasedGovernanceAddress: aliased_governance,
        }
        .abi_encode(),
    );
    let Some(proxy_admin_deployer) = proxy_admin_deployer else {
        return Ok(());
    };
    let proxy_admin_deployer_result =
        GatewayCTMDeployerProxyAdmin::new(proxy_admin_deployer, gw_provider.clone())
            .getResult()
            .call()
            .await
            .context("read GatewayCTMDeployerProxyAdmin.getResult()")?;
    let gateway_ctm_proxy_admin = proxy_admin_deployer_result.chainTypeManagerProxyAdmin;

    let live_gateway_ctm_proxy_admin = verifiers
        .network_verifier
        .try_get_gateway_proxy_admin(ctm_proxy)
        .await
        .context("read Gateway CTM proxy admin")?;
    expect_gateway_deployer_address(
        result,
        "Gateway CTM proxy admin slot",
        gateway_ctm_proxy_admin,
        live_gateway_ctm_proxy_admin,
    );

    let validator_timelock_deployer = expect_create2_params_by_file(
        verifiers,
        result,
        "Gateway ValidatorTimelock deployer",
        "l1-contracts/GatewayCTMDeployerValidatorTimelock",
        GatewayValidatorTimelockDeployerConfig {
            salt: gateway_salt,
            aliasedGovernanceAddress: aliased_governance,
            chainTypeManagerProxyAdmin: gateway_ctm_proxy_admin,
        }
        .abi_encode(),
    );
    if let Some(validator_timelock_deployer) = validator_timelock_deployer {
        let validator_timelock_result = GatewayCTMDeployerValidatorTimelock::new(
            validator_timelock_deployer,
            gw_provider.clone(),
        )
        .getResult()
        .call()
        .await
        .context("read GatewayCTMDeployerValidatorTimelock.getResult()")?;
        expect_gateway_deployer_address(
            result,
            "Gateway ValidatorTimelock deployer proxy",
            validator_timelock,
            validator_timelock_result.validatorTimelockProxy,
        );
    }

    let verifiers_file = if is_zksync_os {
        "l1-contracts/GatewayCTMDeployerVerifiersZKsyncOS"
    } else {
        "l1-contracts/GatewayCTMDeployerVerifiers"
    };
    let verifiers_deployer = expect_create2_params_by_file(
        verifiers,
        result,
        "Gateway verifiers deployer",
        verifiers_file,
        GatewayVerifiersDeployerConfig {
            salt: gateway_salt,
            aliasedGovernanceAddress: aliased_governance,
            testnetVerifier: source_ctm.contracts_config.is_testnet,
            isZKsyncOS: is_zksync_os,
        }
        .abi_encode(),
    );
    if let Some(verifiers_deployer) = verifiers_deployer {
        let verifiers_result =
            GatewayCTMDeployerVerifiers::new(verifiers_deployer, gw_provider.clone())
                .getResult()
                .call()
                .await
                .context("read GatewayCTMDeployerVerifiers.getResult()")?;
        expect_gateway_deployer_address(
            result,
            "Gateway verifiers deployer verifier",
            verifier,
            verifiers_result.verifier,
        );
    }

    let ctm_deployer_file = if is_zksync_os {
        "l1-contracts/GatewayCTMDeployerCTMZKsyncOS"
    } else {
        "l1-contracts/GatewayCTMDeployerCTM"
    };
    let gateway_ctm_config = GatewayCTMFinalConfig {
        baseConfig: GatewayCTMDeployerConfig {
            aliasedGovernanceAddress: aliased_governance,
            salt: gateway_salt,
            eraChainId: U256::from(era_chain_id),
            l1ChainId: U256::from(l1_chain_id),
            testnetVerifier: source_ctm.contracts_config.is_testnet,
            isZKsyncOS: is_zksync_os,
            adminSelectors: admin_cut.selectors.clone(),
            executorSelectors: executor_cut.selectors.clone(),
            mailboxSelectors: mailbox_cut.selectors.clone(),
            gettersSelectors: getters_cut.selectors.clone(),
            migratorSelectors: migrator_cut.selectors.clone(),
            committerSelectors: committer_cut.selectors.clone(),
            bootloaderHash: initialize_data.l2BootloaderBytecodeHash,
            defaultAccountHash: initialize_data.l2DefaultAccountBytecodeHash,
            evmEmulatorHash: initialize_data.l2EvmEmulatorBytecodeHash,
            genesisRoot: parse_bytes32_hex("genesis_root", &genesis_config.genesis_root)?,
            genesisRollupLeafIndex: U256::from(
                genesis_config.genesis_rollup_leaf_index.unwrap_or_default(),
            ),
            genesisBatchCommitment: if is_zksync_os {
                zksync_os_genesis_batch_commitment()
            } else {
                parse_optional_bytes32_hex(
                    "genesis_batch_commitment",
                    genesis_config.genesis_batch_commitment.as_deref(),
                )?
            },
            forceDeploymentsData: Bytes::from(force_deployments_data),
            protocolVersion: U256::from(source_ctm.contracts_config.new_protocol_version),
        },
        chainTypeManagerProxyAdmin: gateway_ctm_proxy_admin,
        validatorTimelockProxy: validator_timelock,
        facets: Facets {
            adminFacet: admin,
            mailboxFacet: mailbox,
            executorFacet: executor,
            gettersFacet: getters,
            migratorFacet: migrator,
            committerFacet: committer,
            diamondInit: diamond_init,
        },
        genesisUpgrade: genesis_upgrade,
        verifier,
    };
    let ctm_deployer = expect_create2_params_by_file(
        verifiers,
        result,
        "Gateway CTM deployer",
        ctm_deployer_file,
        gateway_ctm_config.abi_encode(),
    );
    if let Some(ctm_deployer) = ctm_deployer {
        let ctm_result = GatewayCTMDeployerCTM::new(ctm_deployer, gw_provider.clone())
            .getResult()
            .call()
            .await
            .context("read GatewayCTMDeployerCTM.getResult()")?;
        expect_gateway_deployer_address(
            result,
            "Gateway CTM deployer ServerNotifier implementation",
            server_notifier_impl,
            ctm_result.serverNotifierImplementation,
        );
        expect_gateway_deployer_address(
            result,
            "Gateway CTM deployer ServerNotifier proxy",
            server_notifier_proxy,
            ctm_result.serverNotifierProxy,
        );
        expect_gateway_deployer_address(
            result,
            "Gateway CTM deployer CTM implementation",
            ctm_impl,
            ctm_result.chainTypeManagerImplementation,
        );
        expect_gateway_deployer_address(
            result,
            "Gateway CTM deployer CTM proxy",
            ctm_proxy,
            ctm_result.chainTypeManagerProxy,
        );
        expect_gateway_deployer_bytes(
            result,
            "Gateway CTM deployer diamondCutData",
            diamond_cut_bytes.as_slice(),
            ctm_result.diamondCutData.as_ref(),
        );
    }

    Ok(())
}

fn source_ctm_for_new_gateway<'a>(
    artifact: &'a EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
) -> Result<&'a CtmArtifact> {
    for ctm in &artifact.ctms {
        let scope = format!("ctms.{}", ctm.flavor.label());
        let ctm_proxy = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;
        if ctm_proxy == verifiers.new_gateway_representative_ctm {
            return Ok(ctm);
        }
    }

    anyhow::bail!(
        "new Gateway representative CTM {} is not present in any [ctms.*].state_transition.chain_type_manager_proxy",
        verifiers.new_gateway_representative_ctm
    )
}

fn read_gateway_force_deployments_data(
    new_gateway: &crate::upgrade_verification::artifacts::NewGatewayArtifact,
) -> Result<Vec<u8>> {
    let raw = new_gateway
        .value
        .get("gateway_state_transition")
        .and_then(toml::Value::as_table)
        .and_then(|t| t.get("force_deployments_data"))
        .and_then(toml::Value::as_str)
        .context(
            "new_gateway.gateway_state_transition.force_deployments_data is required; \
             regenerate the [new_gateway] artifact with the updated GatewayVotePreparation script",
        )?;
    hex_bytes(
        "new_gateway.gateway_state_transition.force_deployments_data",
        raw,
    )
}

fn decode_gateway_diamond_cut(
    new_gateway: &crate::upgrade_verification::artifacts::NewGatewayArtifact,
) -> Result<(gateway_signatures::DiamondCutData, Vec<u8>)> {
    let raw = new_gateway
        .value
        .get("diamond_cut_data")
        .and_then(toml::Value::as_str)
        .context("new_gateway.diamond_cut_data is required")?;
    let bytes = hex_bytes("new_gateway.diamond_cut_data", raw)?;
    let diamond_cut = gateway_signatures::DiamondCutData::abi_decode(&bytes)
        .context("decode new_gateway.diamond_cut_data as DiamondCutData")?;
    Ok((diamond_cut, bytes))
}

fn expect_zero_gateway_address(result: &mut VerificationResult, label: &str, addr: Address) {
    if addr == Address::ZERO {
        result.report_ok(&format!("{label} is zero"));
    } else {
        result.report_error(&format!("{label} must be zero, got {addr}"));
    }
}

fn expect_gateway_facet_cut(
    result: &mut VerificationResult,
    label: &str,
    cut: &gateway_signatures::FacetCut,
    expected_facet: Address,
    expected_freezable: bool,
) {
    if cut.facet == expected_facet {
        result.report_ok(&format!(
            "Gateway {label} facet address matches diamond cut"
        ));
    } else {
        result.report_error(&format!(
            "Gateway {label} facet address mismatch: expected {expected_facet}, got {}",
            cut.facet
        ));
    }
    match cut.action {
        gateway_signatures::Action::Add => {}
        gateway_signatures::Action::Replace
        | gateway_signatures::Action::Remove
        | gateway_signatures::Action::__Invalid => {
            result.report_error(&format!("Gateway {label} facet action must be Add"));
        }
    }
    if cut.isFreezable != expected_freezable {
        result.report_error(&format!(
            "Gateway {label} facet isFreezable mismatch: expected {expected_freezable}, got {}",
            cut.isFreezable
        ));
    }
}

fn expect_gateway_deployer_address(
    result: &mut VerificationResult,
    label: &str,
    expected: Address,
    actual: Address,
) {
    if actual == expected {
        result.report_ok(&format!("{label} matches artifact"));
    } else {
        result.report_error(&format!(
            "{label} mismatch: expected {expected}, got {actual}"
        ));
    }
}

fn expect_gateway_deployer_bytes(
    result: &mut VerificationResult,
    label: &str,
    expected: &[u8],
    actual: &[u8],
) {
    if actual == expected {
        result.report_ok(&format!("{label} matches artifact"));
    } else {
        result.report_error(&format!(
            "{label} mismatch: expected 0x{}, got 0x{}",
            hex::encode(expected),
            hex::encode(actual)
        ));
    }
}

fn expect_create2_params_by_file(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    label: &str,
    expected_file: &str,
    expected_constructor_params: Vec<u8>,
) -> Option<Address> {
    let matches: Vec<Address> = verifiers
        .network_verifier
        .create2_known_bytecodes
        .iter()
        .filter_map(|(addr, file)| {
            if file != expected_file {
                return None;
            }
            let params = verifiers
                .network_verifier
                .create2_constructor_params
                .get(addr)?;
            (params.as_slice() == expected_constructor_params.as_slice()).then_some(*addr)
        })
        .collect();

    match matches.as_slice() {
        [] => {
            result.report_error(&format!(
                "{label}: no CREATE2 deployment for {expected_file} with the expected constructor params"
            ));
            None
        }
        [addr] => {
            result.report_ok(&format!("{label}: {expected_file} deployed at {addr}"));
            Some(*addr)
        }
        many => {
            result.report_error(&format!(
                "{label}: found {} CREATE2 deployments for {expected_file} with identical constructor params: {:?}",
                many.len(), many
            ));
            None
        }
    }
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
