// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// This file contains the structs used by the Gateway CTM Deployer contracts.
// The deployment uses a mix of deployer contracts (for contracts requiring owner initialization)
// and direct deployments in scripts (for contracts without owner initialization).
//
// Deployer contracts (5 phases):
// - Phase 1: GatewayCTMDeployerDA - deploys DA contracts (RollupDAManager needs owner transfer)
// - Phase 2: GatewayCTMDeployerProxyAdmin - deploys ProxyAdmin (needs owner transfer)
// - Phase 3: GatewayCTMDeployerValidatorTimelock - deploys ValidatorTimelock (needs owner initialization)
// - Phase 4: GatewayCTMDeployerVerifiers[ZKsyncOS] - deploys verifier contracts (ZKsyncOS needs owner)
// - Phase 5: GatewayCTMDeployerCTM[ZKsyncOS] - deploys ServerNotifier and CTM (needs owner transfer)
//
// Direct deployments in scripts (no owner initialization needed):
// - AdminFacet, MailboxFacet, ExecutorFacet, GettersFacet
// - DiamondInit, L1GenesisUpgrade, Multicall3

/// @notice Configuration parameters for deploying Gateway CTM.
/// @dev This is the full config used to derive configs for each phase.
// solhint-disable-next-line gas-struct-packing
struct GatewayCTMDeployerConfig {
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Chain ID of the Era chain.
    uint256 eraChainId;
    /// @notice Chain ID of the L1 chain.
    uint256 l1ChainId;
    /// @notice Flag indicating whether to use the testnet verifier.
    bool testnetVerifier;
    /// @notice Flag indicating whether to use ZKsync OS mode.
    bool isZKsyncOS;
    /// @notice Array of function selectors for the Admin facet.
    bytes4[] adminSelectors;
    /// @notice Array of function selectors for the Executor facet.
    bytes4[] executorSelectors;
    /// @notice Array of function selectors for the Mailbox facet.
    bytes4[] mailboxSelectors;
    /// @notice Array of function selectors for the Getters facet.
    bytes4[] gettersSelectors;
    /// @notice Hash of the bootloader bytecode.
    bytes32 bootloaderHash;
    /// @notice Hash of the default account bytecode.
    bytes32 defaultAccountHash;
    /// @notice Hash of the EVM emulator bytecode.
    bytes32 evmEmulatorHash;
    /// @notice Root hash of the genesis state.
    bytes32 genesisRoot;
    /// @notice Leaf index in the genesis rollup.
    uint256 genesisRollupLeafIndex;
    /// @notice Commitment of the genesis batch.
    bytes32 genesisBatchCommitment;
    /// @notice Data for force deployments.
    bytes forceDeploymentsData;
    /// @notice The latest protocol version.
    uint256 protocolVersion;
}

/// @notice Addresses of state transition related contracts.
// solhint-disable-next-line gas-struct-packing
struct StateTransitionContracts {
    /// @notice Address of the ChainTypeManager proxy contract.
    address chainTypeManagerProxy;
    /// @notice Address of the ChainTypeManager implementation contract.
    address chainTypeManagerImplementation;
    /// @notice Address of the Verifier contract.
    address verifier;
    /// @notice Address of the VerifierPlonk contract.
    address verifierPlonk;
    /// @notice Address of the VerifierFflonk contract.
    address verifierFflonk;
    /// @notice Address of the Admin facet contract.
    address adminFacet;
    /// @notice Address of the Mailbox facet contract.
    address mailboxFacet;
    /// @notice Address of the Executor facet contract.
    address executorFacet;
    /// @notice Address of the Getters facet contract.
    address gettersFacet;
    /// @notice Address of the DiamondInit contract.
    address diamondInit;
    /// @notice Address of the GenesisUpgrade contract.
    address genesisUpgrade;
    /// @notice Address of the implementation of the ValidatorTimelock contract.
    address validatorTimelockImplementation;
    /// @notice Address of the ValidatorTimelock contract.
    address validatorTimelock;
    /// @notice Address of the ProxyAdmin for ChainTypeManager.
    address chainTypeManagerProxyAdmin;
    /// @notice Address of the ServerNotifier proxy contract.
    address serverNotifierProxy;
    /// @notice Address of the ServerNotifier implementation contract.
    address serverNotifierImplementation;
}

/// @notice Addresses of Data Availability (DA) related contracts.
// solhint-disable-next-line gas-struct-packing
struct DAContracts {
    /// @notice Address of the RollupDAManager contract.
    address rollupDAManager;
    /// @notice Address of the RelayedSLDAValidator contract.
    address relayedSLDAValidator;
    /// @notice Address of the ValidiumL1DAValidator contract.
    address validiumDAValidator;
}

/// @notice Collection of all deployed contracts by the Gateway CTM Deployer phases.
struct DeployedContracts {
    /// @notice Address of the Multicall3 contract.
    address multicall3;
    /// @notice Struct containing state transition related contracts.
    StateTransitionContracts stateTransition;
    /// @notice Struct containing Data Availability related contracts.
    DAContracts daContracts;
    /// @notice Encoded data for the diamond cut operation.
    bytes diamondCutData;
}

// ============ Phase 1: DA Deployer ============

/// @notice Configuration for Phase 1 deployer (DA contracts).
// solhint-disable-next-line gas-struct-packing
struct GatewayDADeployerConfig {
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
}

/// @notice Result from Phase 1 deployer.
// solhint-disable-next-line gas-struct-packing
struct GatewayDADeployerResult {
    /// @notice Address of the RollupDAManager contract.
    address rollupDAManager;
    /// @notice Address of the ValidiumL1DAValidator contract.
    address validiumDAValidator;
    /// @notice Address of the RelayedSLDAValidator contract.
    address relayedSLDAValidator;
}

// ============ Phase 2: ProxyAdmin Deployer ============

/// @notice Configuration for Phase 2 deployer (ProxyAdmin).
// solhint-disable-next-line gas-struct-packing
struct GatewayProxyAdminDeployerConfig {
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
}

/// @notice Result from Phase 2 deployer.
// solhint-disable-next-line gas-struct-packing
struct GatewayProxyAdminDeployerResult {
    /// @notice Address of the ProxyAdmin for ChainTypeManager.
    address chainTypeManagerProxyAdmin;
}

// ============ Phase 3: ValidatorTimelock Deployer ============

/// @notice Configuration for Phase 3 deployer (ValidatorTimelock).
// solhint-disable-next-line gas-struct-packing
struct GatewayValidatorTimelockDeployerConfig {
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Address of the ProxyAdmin (from Phase 2).
    address chainTypeManagerProxyAdmin;
}

/// @notice Result from Phase 3 deployer.
// solhint-disable-next-line gas-struct-packing
struct GatewayValidatorTimelockDeployerResult {
    /// @notice Address of the ValidatorTimelock implementation contract.
    address validatorTimelockImplementation;
    /// @notice Address of the ValidatorTimelock proxy contract.
    address validatorTimelock;
}

// ============ Phase 4: Verifiers Deployer ============

/// @notice Configuration for Phase 4 deployer (all verifiers).
// solhint-disable-next-line gas-struct-packing
struct GatewayVerifiersDeployerConfig {
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Flag indicating whether to use the testnet verifier.
    bool testnetVerifier;
    /// @notice Flag indicating whether to use ZKsync OS mode.
    bool isZKsyncOS;
}

/// @notice Result from Phase 4 deployer.
// solhint-disable-next-line gas-struct-packing
struct GatewayVerifiersDeployerResult {
    /// @notice Address of the VerifierFflonk contract.
    address verifierFflonk;
    /// @notice Address of the VerifierPlonk contract.
    address verifierPlonk;
    /// @notice Address of the main Verifier contract.
    address verifier;
}

// ============ Phase 5: CTM Deployer ============

/// @notice Configuration for Phase 5 deployer (ServerNotifier, CTM).
/// @dev Contains addresses from previous phases.
// solhint-disable-next-line gas-struct-packing
struct GatewayCTMFinalConfig {
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Chain ID of the Era chain.
    uint256 eraChainId;
    /// @notice Chain ID of the L1 chain.
    uint256 l1ChainId;
    /// @notice Flag indicating whether to use ZKsync OS mode.
    bool isZKsyncOS;
    /// @notice Array of function selectors for the Admin facet.
    bytes4[] adminSelectors;
    /// @notice Array of function selectors for the Executor facet.
    bytes4[] executorSelectors;
    /// @notice Array of function selectors for the Mailbox facet.
    bytes4[] mailboxSelectors;
    /// @notice Array of function selectors for the Getters facet.
    bytes4[] gettersSelectors;
    /// @notice Hash of the bootloader bytecode.
    bytes32 bootloaderHash;
    /// @notice Hash of the default account bytecode.
    bytes32 defaultAccountHash;
    /// @notice Hash of the EVM emulator bytecode.
    bytes32 evmEmulatorHash;
    /// @notice Root hash of the genesis state.
    bytes32 genesisRoot;
    /// @notice Leaf index in the genesis rollup.
    uint256 genesisRollupLeafIndex;
    /// @notice Commitment of the genesis batch.
    bytes32 genesisBatchCommitment;
    /// @notice Data for force deployments.
    bytes forceDeploymentsData;
    /// @notice The latest protocol version.
    uint256 protocolVersion;
    // ---- Addresses from previous phases ----
    /// @notice Address of the ProxyAdmin (from Phase 2).
    address chainTypeManagerProxyAdmin;
    /// @notice Address of the ValidatorTimelock proxy (from Phase 3).
    address validatorTimelock;
    /// @notice Address of the Admin facet (deployed directly).
    address adminFacet;
    /// @notice Address of the Getters facet (deployed directly).
    address gettersFacet;
    /// @notice Address of the Mailbox facet (deployed directly).
    address mailboxFacet;
    /// @notice Address of the Executor facet (deployed directly).
    address executorFacet;
    /// @notice Address of the DiamondInit contract (deployed directly).
    address diamondInit;
    /// @notice Address of the GenesisUpgrade contract (deployed directly).
    address genesisUpgrade;
    /// @notice Address of the Verifier contract (from Phase 4).
    address verifier;
}

/// @notice Result from Phase 5 deployer.
// solhint-disable-next-line gas-struct-packing
struct GatewayCTMFinalResult {
    /// @notice Address of the ServerNotifier implementation contract.
    address serverNotifierImplementation;
    /// @notice Address of the ServerNotifier proxy contract.
    address serverNotifierProxy;
    /// @notice Address of the ChainTypeManager implementation contract.
    address chainTypeManagerImplementation;
    /// @notice Address of the ChainTypeManager proxy contract.
    address chainTypeManagerProxy;
    /// @notice Encoded data for the diamond cut operation.
    bytes diamondCutData;
}
