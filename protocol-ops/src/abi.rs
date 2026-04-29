use ethers::contract::abigen;

abigen!(
    BridgehubAbi,
    "../l1-contracts/zkstack-out/L1Bridgehub.sol/L1Bridgehub.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    MessageRootAbi,
    "../l1-contracts/zkstack-out/MessageRootBase.sol/MessageRootBase.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IChainTypeManagerAbi,
    "../l1-contracts/zkstack-out/IChainTypeManager.sol/IChainTypeManager.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    ChainTypeManagerBaseAbi,
    r#"[
        function L1_BYTECODES_SUPPLIER() view returns (address)
    ]"#,
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    TestnetVerifierAbi,
    r#"[
        function IS_TESTNET_VERIFIER() view returns (bool)
    ]"#,
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    ZkChainAbi,
    "../l1-contracts/zkstack-out/IZKChain.sol/IZKChain.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    ValidatorTimelockAbi,
    "../l1-contracts/zkstack-out/IValidatorTimelock.sol/IValidatorTimelock.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IChainAssetHandlerAbi,
    "../l1-contracts/zkstack-out/IChainAssetHandler.sol/IChainAssetHandlerBase.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

// Using IChainTypeManager for the upgradeChainFromVersion function
abigen!(
    ChainTypeManagerUpgradeFnAbi,
    "../l1-contracts/zkstack-out/IChainTypeManager.sol/IChainTypeManager.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    AdminAbi,
    "../l1-contracts/zkstack-out/IAdmin.sol/IAdmin.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    DiamondCutAbi,
    "../l1-contracts/zkstack-out/IDiamondCut.sol/IDiamondCut.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    ChainAdminOwnableAbi,
    "../l1-contracts/zkstack-out/IChainAdminOwnable.sol/IChainAdminOwnable.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IChainAdminAbi,
    "../l1-contracts/zkstack-out/IChainAdmin.sol/IChainAdmin.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IRegisterZKChainAbi,
    "../l1-contracts/zkstack-out/IRegisterZKChain.sol/IRegisterZKChain.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IDeployL2ContractsAbi,
    "../l1-contracts/zkstack-out/IDeployL2Contracts.sol/IDeployL2Contracts.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IDeployPaymasterAbi,
    "../l1-contracts/zkstack-out/IDeployPaymaster.sol/IDeployPaymaster.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IGatewayVotePreparationAbi,
    "../l1-contracts/zkstack-out/IGatewayVotePreparation.sol/IGatewayVotePreparation.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    AdminFunctionsAbi,
    "../l1-contracts/zkstack-out/AdminFunctions.s.sol/AdminFunctions.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IEnableEvmEmulatorAbi,
    "../l1-contracts/zkstack-out/IEnableEvmEmulator.sol/IEnableEvmEmulator.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    DeployGatewayTransactionFiltererAbi,
    "../l1-contracts/zkstack-out/IDeployGatewayTransactionFilterer.sol/IDeployGatewayTransactionFilterer.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    GatewayUtilsAbi,
    "../l1-contracts/zkstack-out/IGatewayUtils.sol/IGatewayUtils.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IDeployCTMAbi,
    "../l1-contracts/zkstack-out/IDeployCTM.sol/IDeployCTM.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IRegisterCTMAbi,
    "../l1-contracts/zkstack-out/IRegisterCTM.sol/IRegisterCTM.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IRegisterOnAllChainsAbi,
    "../l1-contracts/zkstack-out/IRegisterOnAllChains.sol/IRegisterOnAllChains.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IGatewayMigrateTokenBalancesAbi,
    "../l1-contracts/zkstack-out/IGatewayMigrateTokenBalances.sol/IGatewayMigrateTokenBalances.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IFinalizeChainInitAbi,
    "../l1-contracts/zkstack-out/IFinalizeChainInit.sol/IFinalizeChainInit.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IUpgradeV31Abi,
    "../l1-contracts/zkstack-out/IUpgradeV31.sol/IUpgradeV31.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IFinalizeUpgradeAbi,
    "../l1-contracts/zkstack-out/IFinalizeUpgrade.sol/IFinalizeUpgrade.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL1NativeTokenVaultAbi,
    "../l1-contracts/zkstack-out/IL1NativeTokenVault.sol/IL1NativeTokenVault.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL2NativeTokenVaultAbi,
    "../l1-contracts/zkstack-out/IL2NativeTokenVault.sol/IL2NativeTokenVault.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL1AssetRouterAbi,
    "../l1-contracts/zkstack-out/IL1AssetRouter.sol/IL1AssetRouter.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL2AssetRouterAbi,
    "../l1-contracts/zkstack-out/IL2AssetRouter.sol/IL2AssetRouter.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IAssetTrackerBaseAbi,
    "../l1-contracts/zkstack-out/IAssetTrackerBase.sol/IAssetTrackerBase.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL1AssetTrackerAbi,
    "../l1-contracts/zkstack-out/IL1AssetTracker.sol/IL1AssetTracker.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IL2AssetTrackerAbi,
    "../l1-contracts/zkstack-out/IL2AssetTracker.sol/IL2AssetTracker.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    IGWAssetTrackerAbi,
    "../l1-contracts/zkstack-out/IGWAssetTracker.sol/IGWAssetTracker.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    ISetupLegacyBridgeAbi,
    "../l1-contracts/zkstack-out/ISetupLegacyBridge.sol/ISetupLegacyBridge.json",
    event_derives(serde::Deserialize, serde::Serialize)
);
