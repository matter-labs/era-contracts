// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Utils} from "./Utils.sol";

import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

import {GatewayCTMDeployerConfig, DeployedContracts, BLOB_HASH_RETRIEVER_ADDR} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";

import {DeploymentNotifier} from "./DeploymentNotifier.sol";

// solhint-disable gas-custom-errors

struct InnerDeployConfig {
    address deployerAddr;
    bytes32 salt;
}

/// @notice Metadata returned for every deterministic deployment.
struct VerificationInfo {
    string name;
    address addr;
    bytes constructorParams;
}

/// ---------- mirrors of DeployedContracts with VerificationInfo instead of address ----------

struct VerificationDAContracts {
    VerificationInfo rollupDAManager;
    VerificationInfo relayedSLDAValidator;
    VerificationInfo validiumDAValidator;
}

struct VerificationStateTransitionContracts {
    VerificationInfo mailboxFacet;
    VerificationInfo executorFacet;
    VerificationInfo gettersFacet;
    VerificationInfo adminFacet;

    VerificationInfo diamondInit;
    VerificationInfo genesisUpgrade;
    VerificationInfo verifier;

    VerificationInfo validatorTimelock;
    VerificationInfo chainTypeManagerProxyAdmin;
    VerificationInfo serverNotifierProxy;

    VerificationInfo chainTypeManagerImplementation;
    VerificationInfo chainTypeManagerProxy;
}

struct VerificationDeployedContracts {
    VerificationInfo multicall3;
    VerificationDAContracts daContracts;
    VerificationStateTransitionContracts stateTransition;
    bytes diamondCutData;
}

library GatewayCTMDeployerHelper {
    /*───────────────────────────────────────────────────────────────────────────*
     |                                PUBLIC API                               |
     *──────────────────────────────────────────────────────────────────────────*/

    /// @notice Calculates the deterministic addresses for every contract that would be
    ///         deployed by `GatewayCTMDeployer` and packs the results into a single
    ///         `VerificationDeployedContracts` struct.
    ///
    /// @dev The function keeps an internal `DeployedContracts` variable because the
    ///      helper functions that actually compute the addresses still mutate it.
    ///      However, that internal representation is **not** returned ― the caller
    ///      receives only the enriched `verification` struct together with
    ///      `create2Calldata` and the address of the deployer itself.
    ///
    /// @param _create2Salt  Salt that will be passed to the L1 Create2‑factory.
    /// @param config        All runtime data required by the deployer.
    ///
    /// @return verification        Structured metadata about every future deployment.
    /// @return create2Calldata     Calldata that must be sent to the factory so it
    ///                             actually deploys the `GatewayCTMDeployer` contract.
    /// @return ctmDeployerAddress  Deterministic address of the deployer contract.
    function calculateAddresses(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    )
        internal
        returns (
            VerificationDeployedContracts memory verification,
            bytes memory create2Calldata,
            address ctmDeployerAddress
        )
    {
        (bytes32 bytecodeHash, bytes memory deployData) = Utils.getDeploymentCalldata(
            _create2Salt,
            Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayCTMDeployer"),
            abi.encode(config)
        );

        // Create2Factory has the same interface as the usual deployer.
        create2Calldata = deployData;

        ctmDeployerAddress = Utils.getL2AddressViaCreate2Factory(_create2Salt, bytecodeHash, abi.encode(config));

        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: ctmDeployerAddress, salt: config.salt});

        // Caching some values
        bytes32 salt = config.salt;
        uint256 eraChainId = config.eraChainId;
        uint256 l1ChainId = config.l1ChainId;

        verification.multicall3 = _deployInternal("Multicall3", "Multicall3.sol", hex"", innerConfig);
        verification = _deployFacetsAndUpgrades(
            salt,
            eraChainId,
            l1ChainId,
            config.rollupL2DAValidatorAddress,
            config.aliasedGovernanceAddress,
            verification,
            innerConfig
        );

        verification = _deployVerifier(config.testnetVerifier, verification, innerConfig);

        verification.stateTransition.validatorTimelock = _deployInternal(
            "ValidatorTimelock",
            "ValidatorTimelock.sol",
            abi.encode(ctmDeployerAddress, 0),
            innerConfig
        );
        verification.stateTransition.chainTypeManagerProxyAdmin = _deployInternal("ProxyAdmin", "ProxyAdmin.sol", hex"", innerConfig);
        verification.stateTransition.serverNotifierProxy = _deployServerNotifier(salt, verification, innerConfig, ctmDeployerAddress);

        verification = _deployCTM(salt, config, verification, innerConfig);
    }

    /// @notice Converts `VerificationDeployedContracts` into the lightweight
    ///         `DeployedContracts` struct by stripping all metadata except the
    ///         addresses.
    ///
    /// @param verification  Enriched struct holding metadata for every deployment.
    /// @return contracts    Same data but with only the raw addresses kept.
    function convertToDeployedContracts(
        VerificationDeployedContracts memory verification
    ) internal pure returns (DeployedContracts memory contracts) {
        // Top‑level singleton contracts
        contracts.multicall3 = verification.multicall3.addr;

        // ─────────────────────────── DA contracts ────────────────────────────
        contracts.daContracts.rollupDAManager = verification.daContracts.rollupDAManager.addr;
        contracts.daContracts.relayedSLDAValidator = verification.daContracts.relayedSLDAValidator.addr;
        contracts.daContracts.validiumDAValidator = verification.daContracts.validiumDAValidator.addr;

        // ─────────────────────── State‑transition contracts ───────────────────
        contracts.stateTransition.mailboxFacet = verification.stateTransition.mailboxFacet.addr;
        contracts.stateTransition.executorFacet = verification.stateTransition.executorFacet.addr;
        contracts.stateTransition.gettersFacet = verification.stateTransition.gettersFacet.addr;
        contracts.stateTransition.adminFacet = verification.stateTransition.adminFacet.addr;
        contracts.stateTransition.diamondInit = verification.stateTransition.diamondInit.addr;
        contracts.stateTransition.genesisUpgrade = verification.stateTransition.genesisUpgrade.addr;
        contracts.stateTransition.verifier = verification.stateTransition.verifier.addr;
        contracts.stateTransition.validatorTimelock = verification.stateTransition.validatorTimelock.addr;
        contracts.stateTransition.chainTypeManagerProxyAdmin = verification.stateTransition.chainTypeManagerProxyAdmin.addr;
        contracts.stateTransition.serverNotifierProxy = verification.stateTransition.serverNotifierProxy.addr;
        contracts.stateTransition.chainTypeManagerImplementation = verification.stateTransition.chainTypeManagerImplementation.addr;
        contracts.stateTransition.chainTypeManagerProxy = verification.stateTransition.chainTypeManagerProxy.addr;

        // Other raw data that can be copied verbatim
        contracts.diamondCutData = verification.diamondCutData;
    }

    /// @notice Emits a `DeploymentNotifier.notifyAboutDeployment` call for every
    ///         contract contained in the given verification struct.
    /// @param verification  Struct holding the metadata for the deterministic deployments.
    function notifyAboutDeployments(
        VerificationDeployedContracts memory verification
    ) internal {
        // Helper to keep the repetitive code short.
        _notify(verification.multicall3);

        _notify(verification.daContracts.rollupDAManager);
        _notify(verification.daContracts.relayedSLDAValidator);
        _notify(verification.daContracts.validiumDAValidator);

        _notify(verification.stateTransition.mailboxFacet);
        _notify(verification.stateTransition.executorFacet);
        _notify(verification.stateTransition.gettersFacet);
        _notify(verification.stateTransition.adminFacet);
        _notify(verification.stateTransition.diamondInit);
        _notify(verification.stateTransition.genesisUpgrade);
        _notify(verification.stateTransition.verifier);
        _notify(verification.stateTransition.validatorTimelock);
        _notify(verification.stateTransition.chainTypeManagerProxyAdmin);
        _notify(verification.stateTransition.serverNotifierProxy);
        _notify(verification.stateTransition.chainTypeManagerImplementation);
        _notify(verification.stateTransition.chainTypeManagerProxy);
    }

    /// @dev Thin wrapper around `DeploymentNotifier.notifyAboutDeployment` with the
    ///      correct constant for `isZkBytecode`.
    function _notify(VerificationInfo memory info) private {
        DeploymentNotifier.notifyAboutDeployment(
            info.addr,
            info.name,
            info.constructorParams,
            true // Always true for our use‑case
        );
    }

    function _deployServerNotifier(
        bytes32 _salt,
        VerificationDeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig,
        address ctmDeployerAddress
    ) internal returns (VerificationInfo memory) {
        VerificationInfo memory implInfo = _deployInternal(
            "ServerNotifier",
            "ServerNotifier.sol",
            abi.encode(),
            innerConfig
        );

        return
            _deployInternal(
                "TransparentUpgradeableProxy",
                "TransparentUpgradeableProxy.sol",
                abi.encode(
                    implInfo.addr,
                    _deployedContracts.stateTransition.chainTypeManagerProxyAdmin.addr,
                    abi.encodeCall(ServerNotifier.initialize, (ctmDeployerAddress))
                ),
                innerConfig
            );
    }

    function _deployFacetsAndUpgrades(
        bytes32 _salt,
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _rollupL2DAValidatorAddress,
        address _governanceAddress,
        VerificationDeployedContracts memory _verificationContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (VerificationDeployedContracts memory) {
            _verificationContracts.stateTransition.mailboxFacet = _deployInternal(
                "MailboxFacet",
                "Mailbox.sol",
                abi.encode(_eraChainId, _l1ChainId),
                innerConfig
            );

            _verificationContracts.stateTransition.executorFacet = _deployInternal(
                "ExecutorFacet",
                "Executor.sol",
                abi.encode(_l1ChainId),
                innerConfig
            );

        
            _verificationContracts.stateTransition.gettersFacet = _deployInternal("GettersFacet", "Getters.sol", hex"", innerConfig);

        address rollupDAManager;
        (_verificationContracts, rollupDAManager) = _deployRollupDAManager(
            _salt,
            _rollupL2DAValidatorAddress,
            _governanceAddress,
            _verificationContracts,
            innerConfig
        );

        _verificationContracts.stateTransition.adminFacet = _deployInternal(
            "AdminFacet",
            "Admin.sol",
            abi.encode(_l1ChainId, rollupDAManager),
            innerConfig
        );


        _verificationContracts.stateTransition.diamondInit = _deployInternal("DiamondInit", "DiamondInit.sol", hex"", innerConfig);
        _verificationContracts.stateTransition.genesisUpgrade = _deployInternal("L1GenesisUpgrade", "L1GenesisUpgrade.sol", hex"", innerConfig);
        return _verificationContracts;
    }

    function _deployVerifier(
        bool _testnetVerifier,
        VerificationDeployedContracts memory _verificationContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (VerificationDeployedContracts memory) {
        VerificationInfo memory verifierFflonk = _deployInternal("L2VerifierFflonk", "L2VerifierFflonk.sol", hex"", innerConfig);

        VerificationInfo memory verifierPlonk = _deployInternal("L2VerifierPlonk", "L2VerifierPlonk.sol", hex"", innerConfig);

        bytes memory constructorParams = abi.encode(verifierFflonk.addr, verifierPlonk.addr);

        VerificationInfo memory finalVerifier;
        if (_testnetVerifier) {
            finalVerifier = _deployInternal(
                "TestnetVerifier",
                "TestnetVerifier.sol",
                constructorParams,
                innerConfig
            );
        } else {
            finalVerifier = _deployInternal(
                "DualVerifier",
                "DualVerifier.sol",
                constructorParams,
                innerConfig
            );
        }

        _verificationContracts.stateTransition.verifier = finalVerifier;
        return _verificationContracts;
    }

    function _deployRollupDAManager(
        bytes32 _salt,
        address _rollupL2DAValidatorAddress,
        address _governanceAddress,
        VerificationDeployedContracts memory _verificationContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (VerificationDeployedContracts memory, address) {
        VerificationInfo memory daManager = _deployInternal("RollupDAManager", "RollupDAManager.sol", hex"", innerConfig);

        VerificationInfo memory validiumDAValidator = _deployInternal(
            "ValidiumL1DAValidator",
            "ValidiumL1DAValidator.sol",
            hex"",
            innerConfig
        );

        VerificationInfo memory relayedSLDAValidator = _deployInternal(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            hex"",
            innerConfig
        );

        _verificationContracts.daContracts.rollupDAManager = daManager;
        _verificationContracts.daContracts.relayedSLDAValidator = relayedSLDAValidator;
        _verificationContracts.daContracts.validiumDAValidator = validiumDAValidator;

        return (_verificationContracts, daManager.addr);
    }

    function _deployCTM(
        bytes32 _salt,
        GatewayCTMDeployerConfig memory _config,
        VerificationDeployedContracts memory _verificationContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (VerificationDeployedContracts memory) {
        _verificationContracts.stateTransition.chainTypeManagerImplementation = _deployInternal(
            "ChainTypeManager",
            "ChainTypeManager.sol",
            abi.encode(L2_BRIDGEHUB_ADDR),
            innerConfig
        );

        _verificationContracts.stateTransition.chainTypeManagerProxyAdmin = _deployInternal("ProxyAdmin", "ProxyAdmin.sol", hex"", innerConfig);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: _verificationContracts.stateTransition.adminFacet.addr,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: _verificationContracts.stateTransition.gettersFacet.addr,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: _verificationContracts.stateTransition.mailboxFacet.addr,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: _verificationContracts.stateTransition.executorFacet.addr,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.executorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(_verificationContracts.stateTransition.verifier.addr),
            verifierParams: _config.verifierParams,
            l2BootloaderBytecodeHash: _config.bootloaderHash,
            l2DefaultAccountBytecodeHash: _config.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: _config.evmEmulatorHash,
            priorityTxMaxGasLimit: _config.priorityTxMaxGasLimit,
            feeParams: _config.feeParams,
            blobVersionedHashRetriever: BLOB_HASH_RETRIEVER_ADDR
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: _verificationContracts.stateTransition.diamondInit.addr,
            initCalldata: abi.encode(initializeData)
        });

        _verificationContracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: _verificationContracts.stateTransition.genesisUpgrade.addr,
            genesisBatchHash: _config.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(_config.genesisRollupLeafIndex),
            genesisBatchCommitment: _config.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: _config.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: _config.aliasedGovernanceAddress,
            validatorTimelock: _verificationContracts.stateTransition.validatorTimelock.addr,
            chainCreationParams: chainCreationParams,
            protocolVersion: _config.protocolVersion,
            serverNotifier: _verificationContracts.stateTransition.serverNotifierProxy.addr
        });

        _verificationContracts.stateTransition.chainTypeManagerProxy = _deployInternal(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                _verificationContracts.stateTransition.chainTypeManagerImplementation.addr,
                _verificationContracts.stateTransition.chainTypeManagerProxyAdmin.addr,
                abi.encodeCall(ChainTypeManager.initialize, (diamondInitData))
            ),
            innerConfig
        );

        return _verificationContracts;
    }

    function _deployInternal(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (VerificationInfo memory) {
        bytes memory bytecode = Utils.readZKFoundryBytecodeL1(fileName, contractName);

        address computed = L2ContractHelper.computeCreate2Address(
            config.deployerAddr,
            config.salt,
            L2ContractHelper.hashL2Bytecode(bytecode),
            keccak256(params)
        );

        return VerificationInfo({name: contractName, addr: computed, constructorParams: params});
    }

    /// @notice List of factory dependencies needed for the correct execution of
    /// CTMDeployer and healthy functionaling of the system overall
    function getListOfFactoryDeps() external returns (bytes[] memory dependencies) {
        uint256 totalDependencies = 21;
        dependencies = new bytes[](totalDependencies);
        uint256 index = 0;

        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayCTMDeployer");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Multicall3.sol", "Multicall3");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("RollupDAManager.sol", "RollupDAManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidiumL1DAValidator.sol", "ValidiumL1DAValidator");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("RelayedSLDAValidator.sol", "RelayedSLDAValidator");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondInit.sol", "DiamondInit");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("L1GenesisUpgrade.sol", "L1GenesisUpgrade");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("L2VerifierFflonk.sol", "L2VerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("L2VerifierPlonk.sol", "L2VerifierPlonk");
        // Include both verifiers since we cannot determine which one will be used
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("TestnetVerifier.sol", "TestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DualVerifier.sol", "DualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ChainTypeManager.sol", "ChainTypeManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "TransparentUpgradeableProxy.sol",
            "TransparentUpgradeableProxy"
        );
        // Not used in scripts, but definitely needed for CTM to work
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondProxy.sol", "DiamondProxy");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier");

        return dependencies;
    }
}
