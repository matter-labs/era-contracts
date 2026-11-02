#![allow(clippy::too_many_arguments)]

// zk-deployer (zksync-os-integration-tests) deploys and deposits test tokens with these three.
pub mod testnet_erc20_token {
    alloy::sol!(
        #[sol(rpc)]
        TestnetERC20TokenAbi,
        "../l1-contracts/zkstack-out/TestnetERC20Token.sol/TestnetERC20Token.json"
    );
}
pub use testnet_erc20_token::TestnetERC20TokenAbi;

pub mod il1_native_token_vault {
    alloy::sol!(
        #[sol(rpc)]
        IL1NativeTokenVaultAbi,
        "../l1-contracts/zkstack-out/IL1NativeTokenVault.sol/IL1NativeTokenVault.json"
    );
}
pub use il1_native_token_vault::IL1NativeTokenVaultAbi;

pub mod il1_asset_router {
    alloy::sol!(
        #[sol(rpc)]
        IL1AssetRouterAbi,
        "../l1-contracts/zkstack-out/IL1AssetRouter.sol/IL1AssetRouter.json"
    );
}
pub use il1_asset_router::IL1AssetRouterAbi;

pub mod bridgehub {
    alloy::sol!(
        #[sol(rpc)]
        BridgehubAbi,
        "../l1-contracts/zkstack-out/L1Bridgehub.sol/L1Bridgehub.json"
    );
}
pub use bridgehub::BridgehubAbi;

pub mod i_chain_type_manager {
    alloy::sol!(
        #[sol(rpc)]
        IChainTypeManagerAbi,
        "../l1-contracts/zkstack-out/IChainTypeManager.sol/IChainTypeManager.json"
    );
}
pub use i_chain_type_manager::IChainTypeManagerAbi;

pub mod zk_chain {
    alloy::sol!(
        #[sol(rpc)]
        ZkChainAbi,
        "../l1-contracts/zkstack-out/IZKChain.sol/IZKChain.json"
    );
}
pub use zk_chain::ZkChainAbi;

pub mod i_register_zk_chain {
    alloy::sol!(
        #[sol(rpc)]
        IRegisterZKChainAbi,
        "../l1-contracts/zkstack-out/IRegisterZKChain.sol/IRegisterZKChain.json"
    );
}
pub use i_register_zk_chain::IRegisterZKChainAbi;

pub mod admin_functions {
    alloy::sol!(
        #[sol(rpc)]
        AdminFunctionsAbi,
        "../l1-contracts/zkstack-out/AdminFunctions.s.sol/AdminFunctions.json"
    );
}
pub use admin_functions::AdminFunctionsAbi;

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

pub mod access_control_default_admin_rules {
    alloy::sol!(
        #[sol(rpc)]
        interface AccessControlDefaultAdminRulesAbi {
            function defaultAdmin() external view returns (address);
        }
    );
}
pub use access_control_default_admin_rules::AccessControlDefaultAdminRulesAbi;

pub mod i_core_upgrade_prepare {
    alloy::sol!(
        #[sol(rpc)]
        ICoreUpgradePrepareAbi,
        "../l1-contracts/zkstack-out/IUpgradePrepare.sol/ICoreUpgradePrepare.json"
    );
}
pub use i_core_upgrade_prepare::ICoreUpgradePrepareAbi;

pub mod i_ctm_upgrade_prepare {
    alloy::sol!(
        #[sol(rpc)]
        ICTMUpgradePrepareAbi,
        "../l1-contracts/zkstack-out/IUpgradePrepare.sol/ICTMUpgradePrepare.json"
    );
}
pub use i_ctm_upgrade_prepare::ICTMUpgradePrepareAbi;

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
                uint8 pubdataContent;
                bool shouldUnpauseDeposits;
                bool shouldSetDaValidatorPair;
                bool shouldSetPubdataContent;
                bool shouldMakePermanentRollup;
            }

            function finalizeChainInit(FinalizeChainInitParams _params) external;
        }
    );
}
pub use i_finalize_chain_init::IFinalizeChainInitAbi;
