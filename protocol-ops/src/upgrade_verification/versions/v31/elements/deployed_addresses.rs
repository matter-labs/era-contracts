use anyhow::{ensure, Context, Result};

use super::protocol_version::ProtocolVersion;
use crate::upgrade_verification::verifiers::VerificationResult;

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
    primitives::{Address, U256},
    providers::Provider,
    sol,
    sol_types::{SolConstructor, SolValue},
};
use serde::Deserialize;

const MAINNET_CHAIN_ID: u64 = 1;

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

const EXPECTED_FACETS: [BasicFacetInfo; 4] = [
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
];

const EXPECTED_GATEWAY_FACETS: [BasicFacetInfo; 4] = [
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
            &chain_type_manager_addr,
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

            if bytecode.len() == 0 {
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
