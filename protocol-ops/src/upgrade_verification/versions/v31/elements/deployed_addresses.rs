use anyhow::{ensure, Context, Result};

use super::protocol_version::ProtocolVersion;
use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor, EcosystemUpgradeArtifact},
    verifiers::{GenesisConfigKind, VerificationResult, Verifiers},
    versions::v31::MAX_NUMBER_OF_ZK_CHAINS,
};

use super::{
    super::utils::{
        address_from_short_hex,
        address_verifier::AddressVerifier,
        facet_cut_set::{self, FacetCutSet, FacetInfo},
        network_verifier::{Bridgehub as BridgehubSol, BridgehubInfo},
    },
    UpgradeOutput,
};
use alloy::{
    hex::FromHex,
    primitives::{Address, FixedBytes, U256},
    providers::Provider,
    sol,
    sol_types::{SolCall, SolConstructor, SolValue},
};
use serde::Deserialize;
use std::str::FromStr;

const MAINNET_CHAIN_ID: u64 = 1;
// TODO: remove this name here
const CREATE2_FACTORY_CONTRACT_NAME: &str = "Create2Factory";
// TODO: surely there is a way to not hardcode this
const L2_INTEROP_CENTER_ADDR: &str = "0x000000000000000000000000000000000001000d";

sol! {
    contract L1NativeTokenVault {
        constructor(
            address _l1WethAddress,
            address _l1AssetRouter,
            address _l1Nullifier
        );

        function initialize(address _owner, address _bridgedTokenBeacon);
    }

    #[sol(rpc)]
    contract ValidatorTimelock {
        constructor(address _initialOwner, uint32 _executionDelay);
        address public chainTypeManager;
        address public owner;
        uint32 public executionDelay;
    }

    #[sol(rpc)]
    contract L2WrappedBaseTokenStore {
        constructor(address _initialOwner, address _admin);
        address public admin;
        address public owner;
        function l2WBaseTokenAddress(uint256 chainId) external view returns (address l2WBaseTokenAddress);
    }

    #[sol(rpc)]
    contract CTMDeploymentTracker {
        constructor(address _bridgehub, address _l1AssetRouter);
        address public owner;

        function initialize(address _owner);
    }

    #[sol(rpc)]
    contract L1AssetRouter {
        constructor(
            address _l1WethAddress,
            address _bridgehub,
            address _l1Nullifier,
            uint256 _eraChainId,
            address _eraDiamondProxy
        );
        function initialize(address _owner) external;

        /// @dev Address of native token vault.
        address public nativeTokenVault;

        /// @dev Address of legacy bridge.
        address public legacyBridge;

        address public owner;
    }

    contract L1Nullifier {
        constructor(address _bridgehub, uint256 _eraChainId, address _eraDiamondProxy);
    }

    contract L1ERC20Bridge {
        constructor(
            address _nullifier,
            address _assetRouter,
            address _nativeTokenVault,
            uint256 _eraChainId
        );
    }

    contract ChainTypeManager {
        constructor(address _bridgehub);
    }

    #[sol(rpc)]
    contract V31ChainTypeManagerView {
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
    }

    #[sol(rpc)]
    contract L1SharedBridgeLegacy {
        function l2BridgeAddress(uint256 chainId) public view override returns (address l2SharedBridgeAddress);
    }

    /// @notice Faсet structure compatible with the EIP-2535 diamond loupe
    /// @param addr The address of the facet contract
    /// @param selectors The NON-sorted array with selectors associated with facet
    struct Facet {
        address addr;
        bytes4[] selectors;
    }

    #[sol(rpc)]
    contract GettersFacet {
        function getProtocolVersion() external view returns (uint256);
        function facets() external view returns (Facet[] memory result);
    }

    contract AdminFacet {
        constructor(uint256 _l1ChainId, address _rollupDAManager);
    }

    contract ExecutorFacet {
        constructor(uint256 _l1ChainId);
    }

    contract MailboxFacet {
        constructor(uint256 _eraChainId, uint256 _l1ChainId);
    }

    contract BridgehubImpl {
        constructor(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfZKChains);
    }

    #[sol(rpc)]
    contract RollupDAManager{
        function isPairAllowed(address _l1DAValidator, address _l2DAValidator) external view returns (bool);
        address public owner;
    }

    contract TransitionaryOwner {
        constructor(address _governanceAddress);
    }

    contract BridgedTokenBeacon {
        constructor(address _beacon);
    }

    contract MessageRoot {
        constructor(address _bridgehub);
        function initialize();
    }

    contract GovernanceUpgradeTimer {
        constructor(uint256 _initialDelay, uint256 _maxAdditionalDelay, address _timerGovernance, address _initialOwner);
    }

    contract DualVerifier {
        constructor(address _fflonkVerifier, address _plonkVerifier);
    }

    #[sol(rpc)]
    contract ProtocolUpgradeHandler {
        /// @dev ZKsync smart contract that used to operate with L2 via asynchronous L2 <-> L1 communication.
        address public immutable ZKSYNC_ERA;

        /// @dev ZKsync smart contract that is responsible for creating new ZK Chains and changing parameters in existent.
        address public immutable CHAIN_TYPE_MANAGER;

        /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
        address public immutable BRIDGE_HUB;

        /// @dev The nullifier contract that is used for bridging.
        address public immutable L1_NULLIFIER;

        /// @dev The asset router contract that is used for bridging.
        address public immutable L1_ASSET_ROUTER;

        /// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
        address public immutable L1_NATIVE_TOKEN_VAULT;
    }
}

struct BasicFacetInfo {
    name: &'static str,
    is_freezable: bool,
}

const EXPECTED_FACETS: [BasicFacetInfo; 6] = [
    BasicFacetInfo {
        name: "admin_facet",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "getters_facet",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "mailbox_facet",
        is_freezable: true,
    },
    BasicFacetInfo {
        name: "executor_facet",
        is_freezable: true,
    },
    BasicFacetInfo {
        name: "migrator_facet",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "committer_facet",
        is_freezable: true,
    },
];

const EXPECTED_GATEWAY_FACETS: [BasicFacetInfo; 6] = [
    BasicFacetInfo {
        name: "gateway_admin_facet_addr",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "gateway_getters_facet_addr",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "gateway_mailbox_facet_addr",
        is_freezable: true,
    },
    BasicFacetInfo {
        name: "gateway_executor_facet_addr",
        is_freezable: true,
    },
    BasicFacetInfo {
        name: "gateway_migrator_facet_addr",
        is_freezable: false,
    },
    BasicFacetInfo {
        name: "gateway_committer_facet_addr",
        is_freezable: true,
    },
];

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

impl DeployedAddresses {
    // Here we add addresses that will be newly deployed.
    // If the address is already present (for example some existing proxy)
    // we should read its value from the bridgehub, and not depend on data from the config.
    pub fn add_to_verifier(&self, address_verifier: &mut AddressVerifier) {
        address_verifier.add_address(
            self.native_token_vault_implementation_addr,
            "native_token_vault_implementation_addr",
        );
        address_verifier.add_address(self.validator_timelock_addr, "validator_timelock");

        address_verifier.add_address(
            self.bridges.l1_asset_router_implementation_addr,
            "l1_asset_router_implementation_addr",
        );
        address_verifier.add_address(self.bridgehub.message_root_proxy_addr, "l1_message_root");
        address_verifier.add_address(
            self.bridgehub.message_root_implementation_addr,
            "l1_message_root_implementation_addr",
        );

        address_verifier.add_address(
            self.bridgehub.bridgehub_implementation_addr,
            "bridgehub_implementation_addr",
        );
        address_verifier.add_address(
            self.bridges.l1_nullifier_implementation_addr,
            "l1_nullifier_implementation_addr",
        );

        address_verifier.add_address(self.l1_rollup_da_manager, "rollup_da_manager");
        address_verifier.add_address(self.l1_governance_upgrade_timer, "upgrade_timer");
        address_verifier.add_address(self.upgrade_stage_validator, "upgrade_stage_validator");
        self.state_transition.add_to_verifier(address_verifier);
    }
}

impl StateTransition {
    pub fn add_to_verifier(&self, address_verifier: &mut AddressVerifier) {
        address_verifier.add_address(self.admin_facet_addr, "admin_facet");
        address_verifier.add_address(self.default_upgrade_addr, "default_upgrade");
        address_verifier.add_address(self.diamond_init_addr, "diamond_init");
        address_verifier.add_address(self.executor_facet_addr, "executor_facet");
        address_verifier.add_address(self.genesis_upgrade_addr, "genesis_upgrade_addr");
        address_verifier.add_address(self.getters_facet_addr, "getters_facet");
        address_verifier.add_address(self.mailbox_facet_addr, "mailbox_facet");
        address_verifier.add_address(self.migrator_facet_addr, "migrator_facet");
        address_verifier.add_address(self.committer_facet_addr, "committer_facet");
        address_verifier.add_address(
            self.state_transition_implementation_addr,
            "state_transition_implementation_addr",
        );
        address_verifier.add_address(self.verifier_addr, "verifier");
    }
}

impl DeployedAddresses {
    async fn verify_ntv(
        &self,
        _config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
    ) -> Result<()> {
        let l1_ntv_impl_constructor = L1NativeTokenVault::constructorCall::new((
            bridgehub_info.l1_weth_token_address,
            bridgehub_info.l1_asset_router_proxy_addr,
            bridgehub_info.l1_nullifier,
        ))
        .abi_encode();

        result.expect_create2_params(
            verifiers,
            &self.native_token_vault_implementation_addr,
            l1_ntv_impl_constructor,
            "l1-contracts/L1NativeTokenVault",
        );

        Ok(())
    }

    async fn verify_validator_timelock(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
    ) -> Result<()> {
        if self.validator_timelock_addr == Address::ZERO {
            result.report_warn("ValidatorTimelock address is zero");
            return Ok(());
        }
        let execution_delay = if config.l1_chain_id == MAINNET_CHAIN_ID {
            10800
        } else {
            0
        };
        result.expect_create2_params(
            verifiers,
            &self.validator_timelock_addr,
            ValidatorTimelock::constructorCall::new((config.deployer_addr, execution_delay))
                .abi_encode(),
            "l1-contracts/ValidatorTimelock",
        );

        let provider = verifiers.network_verifier.get_l1_provider();
        let validator_timelock = ValidatorTimelock::new(self.validator_timelock_addr, provider);
        let current_owner = validator_timelock.owner().call().await?;
        ensure!(
            current_owner == self.l1_transitionary_owner,
            "ValidatorTimelock owner mismatch: expected {:?}, got {:?}",
            self.l1_transitionary_owner,
            current_owner
        );

        let current_execution_delay = validator_timelock.executionDelay().call().await?;
        ensure!(
            current_execution_delay == execution_delay,
            "ValidatorTimelock execution delay mismatch: expected {}, got {}",
            execution_delay,
            current_execution_delay
        );

        let chain_type_manager = validator_timelock.chainTypeManager().call().await?;
        ensure!(
            chain_type_manager == bridgehub_info.stm_address,
            "ValidatorTimelock chainTypeManager mismatch: expected {:?}, got {:?}",
            bridgehub_info.stm_address,
            chain_type_manager
        );

        Ok(())
    }

    async fn verify_per_chain_info(
        &self,
        _config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
    ) -> Result<()> {
        let bridgehub_instance = BridgehubSol::new(
            bridgehub_info.bridgehub_addr,
            verifiers.network_verifier.get_l1_provider(),
        );
        let all_zkchains = bridgehub_instance
            .getAllZKChainChainIDs()
            .call()
            .await
            .context("getallhyperchain")?;

        for chain in all_zkchains {
            let getters = GettersFacet::new(
                bridgehub_instance.getZKChain(chain).call().await?,
                verifiers.network_verifier.get_l1_provider(),
            );
            let protocol_version = getters.getProtocolVersion().call().await?;
            if protocol_version != Self::expected_previous_protocol_version() {
                let semver_version = ProtocolVersion::from(protocol_version);
                result.report_warn(&format!(
                    "Chain {} has incorrect protocol version {}",
                    chain, semver_version
                ));
            }
        }
        Ok(())
    }

    fn expected_previous_protocol_version() -> U256 {
        U256::from(27) * U256::from(2).pow(U256::from(32))
    }

    async fn verify_l1_asset_router(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
    ) -> Result<()> {
        let era_diamond_proxy = verifiers
            .network_verifier
            .get_chain_diamond_proxy(bridgehub_info.stm_address, config.era_chain_id)
            .await;
        let l1_asset_router_impl_constructor = L1AssetRouter::constructorCall::new((
            bridgehub_info.l1_weth_token_address,
            bridgehub_info.bridgehub_addr,
            bridgehub_info.l1_nullifier,
            U256::from(config.era_chain_id),
            era_diamond_proxy,
        ))
        .abi_encode();

        result.expect_create2_params(
            verifiers,
            &self.bridges.l1_asset_router_implementation_addr,
            l1_asset_router_impl_constructor,
            "l1-contracts/L1AssetRouter",
        );

        let provider = verifiers.network_verifier.get_l1_provider();
        let l1_asset_router =
            L1AssetRouter::new(bridgehub_info.l1_asset_router_proxy_addr, provider);
        let current_owner = l1_asset_router.owner().call().await?;
        if current_owner != config.protocol_upgrade_handler_proxy_address {
            result.report_error(&format!(
                "L1AssetRouter owner mismatch: {} vs {}",
                current_owner, config.protocol_upgrade_handler_proxy_address
            ));
        }

        let legacy_bridge = l1_asset_router.legacyBridge().call().await?;
        ensure!(
            legacy_bridge == bridgehub_info.legacy_bridge,
            "L1AssetRouter legacyBridge mismatch"
        );

        let l1_ntv = l1_asset_router.nativeTokenVault().call().await?;
        ensure!(
            l1_ntv == bridgehub_info.native_token_vault,
            "L1AssetRouter nativeTokenVault mismatch"
        );
        Ok(())
    }

    async fn verify_l1_nullifier(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
    ) -> Result<()> {
        let era_diamond_proxy = verifiers
            .network_verifier
            .get_chain_diamond_proxy(bridgehub_info.stm_address, config.era_chain_id)
            .await;
        let l1nullifier_constructor_data = L1Nullifier::constructorCall::new((
            bridgehub_info.bridgehub_addr,
            U256::from(config.era_chain_id),
            era_diamond_proxy,
        ))
        .abi_encode();

        result.expect_create2_params(
            verifiers,
            &self.bridges.l1_nullifier_implementation_addr,
            l1nullifier_constructor_data,
            "l1-contracts/L1Nullifier",
        );
        Ok(())
    }

    async fn verify_bridgehub_impl(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    ) -> Result<()> {
        const MAX_NUMBER_OF_CHAINS: usize = 100;
        result.expect_create2_params(
            verifiers,
            &self.bridgehub.bridgehub_implementation_addr,
            BridgehubImpl::constructorCall::new((
                U256::from(config.l1_chain_id),
                config.protocol_upgrade_handler_proxy_address,
                U256::from(MAX_NUMBER_OF_CHAINS),
            ))
            .abi_encode(),
            "l1-contracts/Bridgehub",
        );
        Ok(())
    }

    async fn verify_chain_type_manager(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        bridgehub_info: &BridgehubInfo,
        is_gateway: bool,
    ) -> Result<()> {
        let (chain_type_manager_addr, bridgehub_addr) = if is_gateway {
            (
                &config
                    .gateway
                    .gateway_state_transition
                    .chain_type_manager_implementation_addr,
                address_from_short_hex("10002"),
            )
        } else {
            (
                &self.state_transition.state_transition_implementation_addr,
                bridgehub_info.bridgehub_addr,
            )
        };

        result.expect_create2_params(
            verifiers,
            chain_type_manager_addr,
            ChainTypeManager::constructorCall::new((bridgehub_addr,)).abi_encode(),
            "l1-contracts/ChainTypeManager",
        );
        Ok(())
    }

    async fn verify_admin_facet(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        _bridgehub_info: &BridgehubInfo,
        is_gateway: bool,
    ) -> Result<()> {
        let (admin_facet_address, da_manager_address) = if is_gateway {
            (
                &config.gateway.gateway_state_transition.admin_facet_addr,
                config.gateway.gateway_state_transition.rollup_da_manager,
            )
        } else {
            (
                &self.state_transition.admin_facet_addr,
                self.l1_rollup_da_manager,
            )
        };

        result.expect_create2_params(
            verifiers,
            admin_facet_address,
            AdminFacet::constructorCall::new((U256::from(config.l1_chain_id), da_manager_address))
                .abi_encode(),
            "l1-contracts/AdminFacet",
        );
        Ok(())
    }

    async fn verify_executor_facet(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        _bridgehub_info: &BridgehubInfo,
        is_gateway: bool,
    ) -> Result<()> {
        let executor_facet_address = if is_gateway {
            &config.gateway.gateway_state_transition.executor_facet_addr
        } else {
            &self.state_transition.executor_facet_addr
        };

        result.expect_create2_params(
            verifiers,
            executor_facet_address,
            ExecutorFacet::constructorCall::new((U256::from(config.l1_chain_id),)).abi_encode(),
            "l1-contracts/ExecutorFacet",
        );
        Ok(())
    }

    async fn verify_getters_facet(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        _bridgehub_info: &BridgehubInfo,
        is_gateway: bool,
    ) -> Result<()> {
        let getters_facet_address = if is_gateway {
            &config.gateway.gateway_state_transition.getters_facet_addr
        } else {
            &self.state_transition.getters_facet_addr
        };

        result.expect_create2_params(
            verifiers,
            getters_facet_address,
            Vec::new(),
            "l1-contracts/GettersFacet",
        );
        Ok(())
    }

    async fn verify_mailbox_facet(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        _bridgehub_info: &BridgehubInfo,
        is_gateway: bool,
    ) -> Result<()> {
        let mailbox_facet_address = if is_gateway {
            &config.gateway.gateway_state_transition.mailbox_facet_addr
        } else {
            &self.state_transition.mailbox_facet_addr
        };

        result.expect_create2_params(
            verifiers,
            mailbox_facet_address,
            MailboxFacet::constructorCall::new((
                U256::from(config.era_chain_id),
                U256::from(config.l1_chain_id),
            ))
            .abi_encode(),
            "l1-contracts/MailboxFacet",
        );
        Ok(())
    }

    pub async fn get_expected_facet_cuts(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut VerificationResult,
        is_gateway: bool,
    ) -> anyhow::Result<(FacetCutSet, FacetCutSet)> {
        let l1_provider = &verifiers.network_verifier.get_l1_provider();
        let bridgehub_addr = verifiers.bridgehub_address;

        let bridgehub_info = verifiers
            .network_verifier
            .get_bridgehub_info(bridgehub_addr)
            .await;

        let mut facets_to_remove = FacetCutSet::new();
        let getters_facet = GettersFacet::new(bridgehub_info.era_address, l1_provider);
        let current_facets = getters_facet.facets().call().await?;
        for f in current_facets {
            // Note, that when deleting facets, their address must be provided as zero.
            facets_to_remove.add_facet(FacetInfo {
                facet: Address::ZERO,
                is_freezable: false,
                action: facet_cut_set::Action::Remove,
                selectors: f.selectors.iter().map(|x| x.0).collect(),
            });
        }

        let mut facets_to_add = FacetCutSet::new();
        for (l1_facet, gw_facet) in EXPECTED_FACETS.iter().zip(EXPECTED_GATEWAY_FACETS) {
            let address = *verifiers
                .address_verifier
                .name_to_address
                .get(l1_facet.name)
                .unwrap_or_else(|| panic!("{} not found", l1_facet.name));
            let bytecode = l1_provider
                .get_code_at(address)
                .await
                .context(format!("Failed to retrieve the bytecode for {}", address))?;

            if bytecode.is_empty() {
                result.report_error(&format!("No bytecode for facet {}", l1_facet.name));
            }
            let info: Vec<_> =
                evmole::contract_info(evmole::ContractInfoArgs::new(&bytecode.0).with_selectors())
                    .functions
                    .unwrap()
                    .into_iter()
                    .map(|f| f.selector)
                    // We filter out the selector for `getName()` which is equal to 0x17d7de7c.
                    .filter(|selector| selector != &[0x17, 0xd7, 0xde, 0x7c])
                    .collect();

            let facet_address = if is_gateway {
                *verifiers
                    .address_verifier
                    .name_to_address
                    .get(gw_facet.name)
                    .unwrap_or_else(|| panic!("{} not found", gw_facet.name))
            } else {
                *verifiers
                    .address_verifier
                    .name_to_address
                    .get(l1_facet.name)
                    .unwrap_or_else(|| panic!("{} not found", l1_facet.name))
            };

            facets_to_add.add_facet(FacetInfo {
                facet: facet_address,
                is_freezable: l1_facet.is_freezable,
                action: facet_cut_set::Action::Add,
                selectors: info.into_iter().collect(),
            });
        }
        Ok((facets_to_remove, facets_to_add))
    }

    pub async fn verify(
        &self,
        config: &UpgradeOutput,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    ) -> anyhow::Result<()> {
        // Here we should verify all the addresses that we're deploying in a given upgrade.
        // In case of v27, they are:
        // * stm / ctm
        // * bridgehub
        // * l1 nullifier
        // * l1 asset router
        // * l1 native token vault
        let bridgehub_addr = verifiers.bridgehub_address;
        let bridgehub_info = verifiers
            .network_verifier
            .get_bridgehub_info(bridgehub_addr)
            .await;

        self.verify_ntv(config, verifiers, result, &bridgehub_info)
            .await?;
        self.verify_validator_timelock(config, verifiers, result, &bridgehub_info)
            .await
            .context("validator timelock")?;
        self.verify_l1_asset_router(config, verifiers, result, &bridgehub_info)
            .await
            .context("l1 asset")?;
        self.verify_l1_nullifier(config, verifiers, result, &bridgehub_info)
            .await
            .context("l1 nullifier")?;
        self.verify_bridgehub_impl(config, verifiers, result)
            .await?;
        self.verify_chain_type_manager(config, verifiers, result, &bridgehub_info, false)
            .await?;
        self.verify_admin_facet(config, verifiers, result, &bridgehub_info, false)
            .await?;
        self.verify_executor_facet(config, verifiers, result, &bridgehub_info, false)
            .await?;
        self.verify_getters_facet(config, verifiers, result, &bridgehub_info, false)
            .await?;
        self.verify_mailbox_facet(config, verifiers, result, &bridgehub_info, false)
            .await?;

        self.verify_per_chain_info(config, verifiers, result, &bridgehub_info)
            .await
            .context("per chain info")?;

        result.expect_create2_params(
            verifiers,
            &self.state_transition.verifier_plonk_addr,
            Vec::new(),
            "l1-contracts/L1VerifierPlonk",
        );

        result.expect_create2_params(
            verifiers,
            &self.state_transition.verifier_fflonk_addr,
            Vec::new(),
            "l1-contracts/L1VerifierFflonk",
        );

        let expected_constructor_params = DualVerifier::constructorCall::new((
            self.state_transition.verifier_fflonk_addr,
            self.state_transition.verifier_plonk_addr,
        ))
        .abi_encode();

        result.expect_create2_params(
            verifiers,
            &self.state_transition.verifier_addr,
            expected_constructor_params,
            if verifiers.testnet_contracts {
                "l1-contracts/TestnetVerifier"
            } else {
                "l1-contracts/DualVerifier"
            },
        );
        result.expect_create2_params(
            verifiers,
            &self.state_transition.genesis_upgrade_addr,
            Vec::new(),
            "l1-contracts/L1GenesisUpgrade",
        );
        result.expect_create2_params(
            verifiers,
            &self.state_transition.default_upgrade_addr,
            Vec::new(),
            "l1-contracts/DefaultUpgrade",
        );
        result.expect_create2_params(
            verifiers,
            &self.state_transition.diamond_init_addr,
            Vec::new(),
            "l1-contracts/DiamondInit",
        );

        result.expect_create2_params(
            verifiers,
            &self.bridgehub.message_root_implementation_addr,
            bridgehub_info.bridgehub_addr.abi_encode(),
            "l1-contracts/MessageRoot",
        );

        // Check gateway create2
        self.verify_admin_facet(config, verifiers, result, &bridgehub_info, true)
            .await?;
        self.verify_executor_facet(config, verifiers, result, &bridgehub_info, true)
            .await?;
        self.verify_getters_facet(config, verifiers, result, &bridgehub_info, true)
            .await?;
        self.verify_mailbox_facet(config, verifiers, result, &bridgehub_info, true)
            .await?;
        self.verify_chain_type_manager(config, verifiers, result, &bridgehub_info, true)
            .await?;

        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.verifier_plonk_addr,
            Vec::new(),
            "l1-contracts/L1VerifierPlonk",
        );

        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.verifier_fflonk_addr,
            Vec::new(),
            "l1-contracts/L1VerifierFflonk",
        );

        let expected_constructor_params = DualVerifier::constructorCall::new((
            config.gateway.gateway_state_transition.verifier_fflonk_addr,
            config.gateway.gateway_state_transition.verifier_plonk_addr,
        ))
        .abi_encode();

        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.verifier_addr,
            expected_constructor_params,
            if verifiers.testnet_contracts {
                "l1-contracts/TestnetVerifier"
            } else {
                "l1-contracts/DualVerifier"
            },
        );
        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.genesis_upgrade_addr,
            Vec::new(),
            "l1-contracts/L1GenesisUpgrade",
        );
        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.default_upgrade_addr,
            Vec::new(),
            "l1-contracts/DefaultUpgrade",
        );
        result.expect_create2_params(
            verifiers,
            &config.gateway.gateway_state_transition.diamond_init_addr,
            Vec::new(),
            "l1-contracts/DiamondInit",
        );

        result.report_ok("deployed addresses");
        Ok(())
    }
}

sol! {
    #[sol(rpc)]
    contract OwnableLike {
        function owner() external view returns (address);
    }
}

const EIP1967_PROXY_ADMIN_SLOT: &str =
    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

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

async fn verify_per_ctm_v31_provenance(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bridgehub_addr: Address,
) -> Result<()> {
    let interop_center = Address::from_str(L2_INTEROP_CENTER_ADDR)
        .context("invalid L2_INTEROP_CENTER_ADDR literal")?;

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
                interop_center,
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

sol! {
    contract V31AdminFacet {
        constructor(uint256 _l1ChainId, address _rollupDAManager);
    }
    contract V31ExecutorFacet {
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
        // The L1Bridgehub source on the contracts side declares
        // `(address _owner, uint256 _maxNumberOfZKChains)` as of v31, but the
        // deploy-script `DeployL1CoreUtils.getCreationCalldata("L1Bridgehub")`
        // encodes three args `(uint256 _l1ChainId, address _owner, uint256
        // _maxNumberOfZKChains)`; the bytecode actually deployed by the
        // prepare scripts therefore carries the 3-arg ABI tail. We mirror
        // that encoding here so `expect_create2_params` matches the bytes
        // already present in the executed bundle.
        constructor(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfZKChains);
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
    contract V31MessageRoot {
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
/// Scope is the contracts whose constructor arguments are fully derivable
/// from the artifact + live RPC + the `--era-chain-id` CLI flag. Contracts
/// with constructor args that are awkward to derive without additional
/// inputs (e.g. `MailboxFacet._eip7702Checker` / `_isTestnet`,
/// `MessageRoot._eraGatewayChainId`,
/// `ChainTypeManager._interopCenter` / `_permissionlessValidator`,
/// `L1ChainAssetHandler._owner`, `L1Bridgehub._owner`) are deliberately
/// not yet wired — adding each is mechanical: append a constructor abi via
/// `sol!` above and a new `expect_create2_params(...)` call here.
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
    genesis_config_kind: GenesisConfigKind,
    result: &mut VerificationResult,
) -> Result<()> {
    result.print_info("== Deployment provenance ==");

    let provider = verifiers.network_verifier.get_l1_provider();
    let l1_chain_id = verifiers
        .network_verifier
        .try_get_l1_chain_id()
        .await
        .unwrap_or_else(|err| panic!("Failed to fetch L1 chain id for provenance: {err}"));

    // Era / ZKsync OS file-name split for the v31 verifier contracts.
    // `AllContractsHashes.json` ships per-flavour verifiers since v30.
    let (verifier_plonk_file, verifier_fflonk_file, dual_verifier_file) = match genesis_config_kind
    {
        GenesisConfigKind::Era => (
            "l1-contracts/EraVerifierPlonk",
            "l1-contracts/EraVerifierFflonk",
            "l1-contracts/EraDualVerifier",
        ),
        GenesisConfigKind::ZksyncOs => (
            "l1-contracts/ZKsyncOSVerifierPlonk",
            "l1-contracts/ZKsyncOSVerifierFflonk",
            "l1-contracts/ZKsyncOSDualVerifier",
        ),
    };

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

    let is_zksync_os = matches!(genesis_config_kind, GenesisConfigKind::ZksyncOs);
    let is_testnet = artifact.contracts_config.is_testnet;

    // Contracts with no constructor args — `expect_create2_params(addr, &[],
    // expected_file)` works as-is.
    for (name, expected_file) in [
        ("genesis_upgrade_addr", "l1-contracts/L1GenesisUpgrade"),
        ("getters_facet_addr", "l1-contracts/GettersFacet"),
        // v31 settlement-layer upgrade contract; takes the slot of the
        // legacy `DefaultUpgrade` in `state_transition.default_upgrade_addr`.
        // No constructor args.
        (
            "default_upgrade",
            "l1-contracts/EraSettlementLayerV31Upgrade",
        ),
        ("verifier_plonk_addr", verifier_plonk_file),
        ("verifier_fflonk_addr", verifier_fflonk_file),
    ] {
        if let Some(addr) = lookup(name) {
            result.expect_create2_params(verifiers, &addr, Vec::<u8>::new(), expected_file);
        }
    }
    // DiamondInit takes `(bool _isZKsyncOS)` per
    // `DeployCTML1OrGateway.getCreationCalldata`. The encoded value is a
    // single 32-byte word.
    if let Some(diamond_init) = lookup("diamond_init_addr") {
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

    // Single-uint constructors.
    if let Some(executor) = lookup("executor_facet_addr") {
        result.expect_create2_params(
            verifiers,
            &executor,
            V31ExecutorFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
            "l1-contracts/ExecutorFacet",
        );
    }

    // AdminFacet(l1ChainId, rollupDAManager).
    if let (Some(admin), Some(rollup_da_manager)) =
        (lookup("admin_facet_addr"), lookup("rollup_da_manager"))
    {
        result.expect_create2_params(
            verifiers,
            &admin,
            V31AdminFacet::constructorCall::new((U256::from(l1_chain_id), rollup_da_manager))
                .abi_encode(),
            "l1-contracts/AdminFacet",
        );
    }

    // DualVerifier(fflonk, plonk). Stage / testnet environments deploy the
    // `*TestnetVerifier` flavour instead of `*DualVerifier`; legacy PUVT
    // gated this on a `--testnet-contracts` flag, but for v31 we accept
    // either name (the constructor args are identical). Pick whichever
    // file the deployment was actually identified as before calling
    // `expect_create2_params`, so we don't double-report on a name miss.
    if let (Some(verifier), Some(fflonk), Some(plonk)) = (
        lookup("verifier"),
        lookup("verifier_fflonk_addr"),
        lookup("verifier_plonk_addr"),
    ) {
        let testnet_verifier_file = match genesis_config_kind {
            GenesisConfigKind::Era => "l1-contracts/EraTestnetVerifier",
            GenesisConfigKind::ZksyncOs => "l1-contracts/ZKsyncOSTestnetVerifier",
        };
        let resolved_file = verifiers
            .network_verifier
            .create2_known_bytecodes
            .get(&verifier)
            .cloned();
        let expected_file = match resolved_file.as_deref() {
            Some(file) if file == testnet_verifier_file => testnet_verifier_file,
            _ => dual_verifier_file,
        };
        result.expect_create2_params(
            verifiers,
            &verifier,
            V31DualVerifier::constructorCall::new((fflonk, plonk)).abi_encode(),
            expected_file,
        );
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
    // require both the chain id and the chain's diamond proxy. The CLI requires
    // `--era-chain-id`; the diamond proxy must resolve from Bridgehub.
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
            V31ExecutorFacet::constructorCall::new((U256::from(l1_chain_id),)).abi_encode(),
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
                    U256::from(l1_chain_id),
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
    // The deploy script (`DeployL1CoreUtils.getCreationCalldata`)
    // populates the second arg from `config.l1ChainId` rather than a
    // distinct gateway chain id, so the deployed bytecode's
    // `_eraGatewayChainId` immutable equals the L1 chain id; mirror that
    // encoding here.
    if let (Some(message_root_impl), Some(chain_asset_handler)) = (
        lookup("message_root_implementation_addr"),
        chain_asset_handler_proxy,
    ) {
        result.expect_create2_params(
            verifiers,
            &message_root_impl,
            V31MessageRoot::constructorCall::new((
                bridgehub_addr,
                U256::from(l1_chain_id),
                chain_asset_handler,
            ))
            .abi_encode(),
            "l1-contracts/L1MessageRoot",
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

    Ok(())
}
