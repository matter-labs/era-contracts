// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

enum EcosystemContract {
    AssetTracker
    ,Bridgehub
    ,ChainAssetHandler
    ,ChainRegistrar
    ,CTMDeploymentTracker
    ,ContractRegistry
    ,BytecodesSupplier
    ,Governance
    ,InteropCenter
    ,L1AssetRouter
    ,L2AssetRouter
    ,L2SharedBridgeLegacy
    ,L1NativeTokenVault
    ,L2NativeTokenVault
    ,L1ERC20Bridge
    ,L1Nullifier
    ,BridgedStandardERC20
    ,BridgedTokenBeacon
    ,BeaconProxy
    ,RollupDAManager
    ,Verifier
    ,VerifierFflonk
    ,VerifierPlonk
    ,ValidatorTimelock
    ,ProxyAdmin
    ,ServerNotifier
    ,GovernanceUpgradeTimer
    ,MessageRoot
    ,WrappedBaseTokenStore /// todo check if needed
    ,L1ByteCodeSupplier /// todo was removed from contracts, still needed in Server?
    ,Multicall3
    ,TransparentUpgradeableProxy
}

enum CTMContract {
    ChainTypeManager
    ,L1GenesisUpgrade
    ,DefaultUpgrade
    ,AdminFacet
    ,ExecutorFacet
    ,GettersFacet
    ,MailboxFacet
    ,DiamondProxy
    ,DiamondInit
    ,ChainAdminOwnable
    ,ChainAdmin
    ,RollupL1DAValidator
    ,RollupL2DAValidator
    ,ValidiumL1DAValidator
    ,ValidiumL2DAValidator
    ,AvailL1DAValidator
    ,AvailL2DAValidator
    ,DummyAvailBridge
    ,GatewayTransactionFilterer
    ,AccessControlRestriction
    /// kl todo finalize list here.
}

enum AllContracts {
    AssetTracker
    ,Bridgehub
    ,ChainAssetHandler
    ,ChainRegistrar
    ,ConsensusRegistry
    ,CTMDeploymentTracker
    ,BytecodesSupplier
    ,ContractRegistry
    ,InteropCenter
    ,Governance
    ,L2AdminFactory
    ,L2ProxyAdminDeployer
    ,L1AssetRouter
    ,L2AssetRouter
    ,L2SharedBridgeLegacy
    ,L2SharedBridgeLegacyDev
    ,L1NativeTokenVault
    ,L2NativeTokenVault
    ,L2WrappedBaseToken
    ,L1ERC20Bridge
    ,L1Nullifier
    ,BridgedStandardERC20
    ,BridgedTokenBeacon
    ,UpgradeableBeacon
    ,BeaconProxy
    ,RollupDAManager
    ,TimestampAsserter
    ,SystemTransparentUpgradeableProxy
    ,L2GatewayUpgrade
    ,Verifier
    ,VerifierFflonk
    ,VerifierPlonk
    ,ValidatorTimelock
    ,DualVerifier
    ,TestnetVerifier
    ,ProxyAdmin
    ,ServerNotifier
    ,GovernanceUpgradeTimer
    ,MessageRoot
    ,WrappedBaseTokenStore /// todo check if needed
    ,L1ByteCodeSupplier /// todo was removed from contracts, still needed in Server?
    ,Multicall3
    ,TransparentUpgradeableProxy
    ,ChainTypeManager
    ,L1GenesisUpgrade
    ,DefaultUpgrade
    ,L1V29Upgrade
    ,L2V29Upgrade
    ,AdminFacet
    ,ExecutorFacet
    ,GettersFacet
    ,MailboxFacet
    ,DiamondProxy
    ,DiamondInit
    ,ChainAdminOwnable
    ,ChainAdmin
    ,RollupL1DAValidator
    ,RollupL2DAValidator
    ,ValidiumL1DAValidator
    ,ValidiumL2DAValidator
    ,RelayedSLDAValidator
    ,ForceDeployUpgrader
    ,AvailL1DAValidator
    ,AvailL2DAValidator
    ,DummyAvailBridge
    ,GatewayTransactionFilterer
    ,AccessControlRestriction
    ,PermanentRestriction
    ,UpgradeStageValidator
    ,TransitionaryOwner
    ,GatewayUpgrade
    /// kl todo finalize list here.
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IContractRegistry {

    function ecosystemContractAddress(EcosystemContract _ecosystemContract) external view returns (address);

    function ctmContractAddress(address _chainTypeManager, CTMContract _ctmContract) external view returns (address);

    function setEcosystemContractAddress(EcosystemContract _ecosystemContract, address _contractAddress) external;

    function setCTMContractAddress(address _chainTypeManager, CTMContract _ctmContract, address _contractAddress) external;

    function ecosystemContractFromContract(AllContracts _contract) external view returns (EcosystemContract);

    function ctmContractFromContract(AllContracts _contract) external view returns (CTMContract);
}
