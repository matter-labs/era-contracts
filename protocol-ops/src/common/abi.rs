#![allow(clippy::too_many_arguments)]

pub mod testnet_erc20_token {
    alloy::sol!(
        #[sol(rpc)]
        TestnetERC20TokenAbi,
        "../l1-contracts/zkstack-out/TestnetERC20Token.sol/TestnetERC20Token.json"
    );
}
pub use testnet_erc20_token::TestnetERC20TokenAbi;

pub mod bridgehub {
    alloy::sol!(
        #[sol(rpc)]
        BridgehubAbi,
        "../l1-contracts/zkstack-out/L1Bridgehub.sol/L1Bridgehub.json"
    );
}
pub use bridgehub::BridgehubAbi;

pub mod message_root {
    alloy::sol!(
        #[sol(rpc)]
        MessageRootAbi,
        "../l1-contracts/zkstack-out/MessageRootBase.sol/MessageRootBase.json"
    );
}
pub use message_root::MessageRootAbi;

pub mod i_chain_type_manager {
    alloy::sol!(
        #[sol(rpc)]
        IChainTypeManagerAbi,
        "../l1-contracts/zkstack-out/IChainTypeManager.sol/IChainTypeManager.json"
    );
}
pub use i_chain_type_manager::IChainTypeManagerAbi;

pub mod i_ctm_release {
    alloy::sol!(
        #[sol(rpc)]
        ICTMReleaseAbi,
        "../l1-contracts/zkstack-out/ICTMRelease.sol/ICTMRelease.json"
    );
}
pub use i_ctm_release::ICTMReleaseAbi;

pub mod zk_chain {
    alloy::sol!(
        #[sol(rpc)]
        ZkChainAbi,
        "../l1-contracts/zkstack-out/IZKChain.sol/IZKChain.json"
    );
}
pub use zk_chain::ZkChainAbi;

pub mod validator_timelock {
    alloy::sol!(
        #[sol(rpc)]
        ValidatorTimelockAbi,
        "../l1-contracts/zkstack-out/IValidatorTimelock.sol/IValidatorTimelock.json"
    );
}
pub use validator_timelock::ValidatorTimelockAbi;

pub mod i_chain_asset_handler {
    alloy::sol!(
        #[sol(rpc)]
        IChainAssetHandlerAbi,
        "../l1-contracts/zkstack-out/IChainAssetHandler.sol/IChainAssetHandlerBase.json"
    );
}
pub use i_chain_asset_handler::IChainAssetHandlerAbi;

// Using IChainTypeManager for the upgradeChainFromVersion function
pub mod chain_type_manager_upgrade_fn {
    alloy::sol!(
        #[sol(rpc)]
        ChainTypeManagerUpgradeFnAbi,
        "../l1-contracts/zkstack-out/IChainTypeManager.sol/IChainTypeManager.json"
    );
}
pub use chain_type_manager_upgrade_fn::ChainTypeManagerUpgradeFnAbi;

pub mod admin {
    alloy::sol!(
        #[sol(rpc)]
        AdminAbi,
        "../l1-contracts/zkstack-out/IAdmin.sol/IAdmin.json"
    );
}
pub use admin::AdminAbi;

pub mod diamond_cut {
    alloy::sol!(
        #[sol(rpc)]
        DiamondCutAbi,
        "../l1-contracts/zkstack-out/IDiamondCut.sol/IDiamondCut.json"
    );
}
pub use diamond_cut::DiamondCutAbi;

pub mod chain_admin_ownable {
    alloy::sol!(
        #[sol(rpc)]
        ChainAdminOwnableAbi,
        "../l1-contracts/zkstack-out/IChainAdminOwnable.sol/IChainAdminOwnable.json"
    );
}
pub use chain_admin_ownable::ChainAdminOwnableAbi;

pub mod i_chain_admin {
    alloy::sol!(
        #[sol(rpc)]
        IChainAdminAbi,
        "../l1-contracts/zkstack-out/IChainAdmin.sol/IChainAdmin.json"
    );
}
pub use i_chain_admin::IChainAdminAbi;

pub mod i_register_zk_chain {
    alloy::sol!(
        #[sol(rpc)]
        IRegisterZKChainAbi,
        "../l1-contracts/zkstack-out/IRegisterZKChain.sol/IRegisterZKChain.json"
    );
}
pub use i_register_zk_chain::IRegisterZKChainAbi;

pub mod i_gateway_vote_preparation {
    alloy::sol!(
        #[sol(rpc)]
        IGatewayVotePreparationAbi,
        "../l1-contracts/zkstack-out/IGatewayVotePreparation.sol/IGatewayVotePreparation.json"
    );
}
pub use i_gateway_vote_preparation::IGatewayVotePreparationAbi;

pub mod admin_functions {
    alloy::sol!(
        #[sol(rpc)]
        AdminFunctionsAbi,
        "../l1-contracts/zkstack-out/AdminFunctions.s.sol/AdminFunctions.json"
    );
}
pub use admin_functions::AdminFunctionsAbi;

pub mod deploy_gateway_transaction_filterer {
    alloy::sol!(
        #[sol(rpc)]
        DeployGatewayTransactionFiltererAbi,
        "../l1-contracts/zkstack-out/IDeployGatewayTransactionFilterer.sol/IDeployGatewayTransactionFilterer.json"
    );
}
pub use deploy_gateway_transaction_filterer::DeployGatewayTransactionFiltererAbi;

pub mod gateway_utils {
    alloy::sol!(
        #[sol(rpc)]
        GatewayUtilsAbi,
        "../l1-contracts/zkstack-out/IGatewayUtils.sol/IGatewayUtils.json"
    );
}
pub use gateway_utils::GatewayUtilsAbi;

pub mod i_deploy_ctm {
    alloy::sol!(
        #[sol(rpc)]
        IDeployCTMAbi,
        "../l1-contracts/zkstack-out/IDeployCTM.sol/IDeployCTM.json"
    );
}
pub use i_deploy_ctm::IDeployCTMAbi;

pub mod i_register_ctm {
    alloy::sol!(
        #[sol(rpc)]
        IRegisterCTMAbi,
        "../l1-contracts/zkstack-out/IRegisterCTM.sol/IRegisterCTM.json"
    );
}
pub use i_register_ctm::IRegisterCTMAbi;

pub mod i_deploy_l1_core_contracts {
    alloy::sol!(
        #[sol(rpc)]
        IDeployL1CoreContractsAbi,
        "../l1-contracts/zkstack-out/IDeployL1CoreContracts.sol/IDeployL1CoreContracts.json"
    );
}
pub use i_deploy_l1_core_contracts::IDeployL1CoreContractsAbi;

pub mod i_register_on_all_chains {
    alloy::sol!(
        #[sol(rpc)]
        IRegisterOnAllChainsAbi,
        "../l1-contracts/zkstack-out/IRegisterOnAllChains.sol/IRegisterOnAllChains.json"
    );
}
pub use i_register_on_all_chains::IRegisterOnAllChainsAbi;

pub mod il1_native_token_vault {
    alloy::sol!(
        #[sol(rpc)]
        IL1NativeTokenVaultAbi,
        "../l1-contracts/zkstack-out/IL1NativeTokenVault.sol/IL1NativeTokenVault.json"
    );
}
pub use il1_native_token_vault::IL1NativeTokenVaultAbi;

pub mod il2_native_token_vault {
    alloy::sol!(
        #[sol(rpc)]
        IL2NativeTokenVaultAbi,
        "../l1-contracts/zkstack-out/IL2NativeTokenVault.sol/IL2NativeTokenVault.json"
    );
}
pub use il2_native_token_vault::IL2NativeTokenVaultAbi;

pub mod il1_asset_router {
    alloy::sol!(
        #[sol(rpc)]
        IL1AssetRouterAbi,
        "../l1-contracts/zkstack-out/IL1AssetRouter.sol/IL1AssetRouter.json"
    );
}
pub use il1_asset_router::IL1AssetRouterAbi;

pub mod il2_asset_router {
    alloy::sol!(
        #[sol(rpc)]
        IL2AssetRouterAbi,
        "../l1-contracts/zkstack-out/IL2AssetRouter.sol/IL2AssetRouter.json"
    );
}
pub use il2_asset_router::IL2AssetRouterAbi;

pub mod ctm_ext {
    alloy::sol!(
        #[sol(rpc)]
        interface IChainTypeManagerExt {
            function L1_BYTECODES_SUPPLIER() external view returns (address);
        }
    );
}
pub use ctm_ext::IChainTypeManagerExt;

pub mod testnet_verifier {
    alloy::sol!(
        #[sol(rpc)]
        interface ITestnetVerifier {
            function isTestnetVerifier() external view returns (bool);
            // Legacy pre-v34 name (a public constant on testnet verifiers of those versions).
            function IS_TESTNET_VERIFIER() external view returns (bool);
        }
    );
}
pub use testnet_verifier::ITestnetVerifier;

pub mod access_control_default_admin_rules {
    alloy::sol!(
        #[sol(rpc)]
        interface AccessControlDefaultAdminRulesAbi {
            function defaultAdmin() external view returns (address);
        }
    );
}
pub use access_control_default_admin_rules::AccessControlDefaultAdminRulesAbi;

pub mod i_core_upgrade_v31 {
    alloy::sol!(
        #[sol(rpc)]
        ICoreUpgradeV31Abi,
        "../l1-contracts/zkstack-out/IUpgradeV31.sol/ICoreUpgradeV31.json"
    );
}
pub use i_core_upgrade_v31::ICoreUpgradeV31Abi;

pub mod i_ctm_upgrade_v31 {
    alloy::sol!(
        #[sol(rpc)]
        ICTMUpgradeV31Abi,
        "../l1-contracts/zkstack-out/IUpgradeV31.sol/ICTMUpgradeV31.json"
    );
}
pub use i_ctm_upgrade_v31::ICTMUpgradeV31Abi;

pub mod i_finalize_chain_init {
    // Hand-declared: the artifact JSON's `enum L2DACommitmentScheme`
    // internalType breaks sol!'s JSON path, so the struct is declared inline
    // with `uint8` (identical ABI encoding). Field order verified against
    // zkstack-out/IFinalizeChainInit.sol/IFinalizeChainInit.json.
    alloy::sol!(
        interface IFinalizeChainInitAbi {
            struct FinalizeChainInitParams {
                address chainAdmin;
                address accessControlRestriction;
                address diamondProxy;
                address bridgehub;
                uint256 chainId;
                address l1DaValidator;
                address tokenMultiplierSetter;
                uint8 l2DaCommitmentScheme;
                bool shouldUnpauseDeposits;
                bool shouldSetDaValidatorPair;
                bool shouldMakePermanentRollup;
            }

            function finalizeChainInit(FinalizeChainInitParams _params) external;
        }
    );
}
pub use i_finalize_chain_init::IFinalizeChainInitAbi;
