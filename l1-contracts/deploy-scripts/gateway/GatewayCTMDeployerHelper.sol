// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Utils} from "../Utils.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";

// solhint-disable gas-custom-errors

struct InnerDeployConfig {
    address deployerAddr;
    bytes32 salt;
}

library GatewayCTMDeployerHelper {
    function calculateAddresses(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    ) internal returns (DeployedContracts memory contracts, bytes memory create2Calldata, address ctmDeployerAddress) {
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

        contracts.multicall3 = _deployInternal("Multicall3", "Multicall3.sol", hex"", innerConfig);

        contracts = _deployFacetsAndUpgrades(
            salt,
            eraChainId,
            l1ChainId,
            config.aliasedGovernanceAddress,
            config.isZKsyncOS,
            contracts,
            innerConfig
        );
        contracts = _deployVerifier(
            config.testnetVerifier,
            config.isZKsyncOS,
            contracts,
            innerConfig,
            config.aliasedGovernanceAddress
        );

        contracts.stateTransition.validatorTimelockImplementation = _deployInternal(
            "ValidatorTimelock",
            "ValidatorTimelock.sol",
            abi.encode(L2_BRIDGEHUB_ADDR),
            innerConfig
        );

        contracts.stateTransition.chainTypeManagerProxyAdmin = _deployInternal(
            "ProxyAdmin",
            "ProxyAdmin.sol",
            hex"",
            innerConfig
        );

        contracts.stateTransition.validatorTimelock = _deployInternal(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                contracts.stateTransition.validatorTimelockImplementation,
                contracts.stateTransition.chainTypeManagerProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.aliasedGovernanceAddress, 0))
            ),
            innerConfig
        );

        contracts.stateTransition.serverNotifierProxy = _deployServerNotifier(
            contracts,
            innerConfig,
            ctmDeployerAddress
        );

        contracts = _deployCTM(salt, config, contracts, innerConfig);
    }

    function _deployServerNotifier(
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig,
        address ctmDeployerAddress
    ) internal returns (address) {
        address serverNotifierImplementation = _deployInternal(
            "ServerNotifier",
            "ServerNotifier.sol",
            abi.encode(),
            innerConfig
        );
        _deployedContracts.stateTransition.serverNotifierImplementation = serverNotifierImplementation;

        address serverNotifier = _deployInternal(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                serverNotifierImplementation,
                _deployedContracts.stateTransition.chainTypeManagerProxyAdmin,
                abi.encodeCall(ServerNotifier.initialize, (ctmDeployerAddress))
            ),
            innerConfig
        );

        return serverNotifier;
    }

    function _deployFacetsAndUpgrades(
        bytes32 _salt,
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _governanceAddress,
        bool _isZKsyncOS,
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (DeployedContracts memory) {
        _deployedContracts.stateTransition.mailboxFacet = _deployInternal(
            "MailboxFacet",
            "Mailbox.sol",
            abi.encode(_eraChainId, _l1ChainId),
            innerConfig
        );

        _deployedContracts.stateTransition.executorFacet = _deployInternal(
            "ExecutorFacet",
            "Executor.sol",
            abi.encode(_l1ChainId),
            innerConfig
        );

        _deployedContracts.stateTransition.gettersFacet = _deployInternal(
            "GettersFacet",
            "Getters.sol",
            hex"",
            innerConfig
        );

        address rollupDAManager;
        (_deployedContracts, rollupDAManager) = _deployRollupDAManager(
            _salt,
            _governanceAddress,
            _deployedContracts,
            innerConfig
        );
        _deployedContracts.stateTransition.adminFacet = _deployInternal(
            "AdminFacet",
            "Admin.sol",
            abi.encode(_l1ChainId, rollupDAManager),
            innerConfig
        );

        _deployedContracts.stateTransition.diamondInit = _deployInternal(
            "DiamondInit",
            "DiamondInit.sol",
            abi.encode(_isZKsyncOS),
            innerConfig
        );
        _deployedContracts.stateTransition.genesisUpgrade = _deployInternal(
            "L1GenesisUpgrade",
            "L1GenesisUpgrade.sol",
            hex"",
            innerConfig
        );

        return _deployedContracts;
    }

    function _deployVerifier(
        bool _testnetVerifier,
        bool _isZKsyncOS,
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig,
        address _verifierOwner
    ) internal returns (DeployedContracts memory) {
        address verifierFflonk;
        address verifierPlonk;

        if (_isZKsyncOS) {
            verifierFflonk = _deployInternal(
                "ZKsyncOSVerifierFflonk",
                "ZKsyncOSVerifierFflonk.sol",
                hex"",
                innerConfig
            );
            verifierPlonk = _deployInternal("ZKsyncOSVerifierPlonk", "ZKsyncOSVerifierPlonk.sol", hex"", innerConfig);
        } else {
            verifierFflonk = _deployInternal("EraVerifierFflonk", "EraVerifierFflonk.sol", hex"", innerConfig);
            verifierPlonk = _deployInternal("EraVerifierPlonk", "EraVerifierPlonk.sol", hex"", innerConfig);
        }

        _deployedContracts.stateTransition.verifierFflonk = verifierFflonk;
        _deployedContracts.stateTransition.verifierPlonk = verifierPlonk;

        if (_testnetVerifier) {
            if (_isZKsyncOS) {
                _deployedContracts.stateTransition.verifier = _deployInternal(
                    "ZKsyncOSTestnetVerifier",
                    "ZKsyncOSTestnetVerifier.sol",
                    abi.encode(verifierFflonk, verifierPlonk, _verifierOwner),
                    innerConfig
                );
            } else {
                _deployedContracts.stateTransition.verifier = _deployInternal(
                    "EraTestnetVerifier",
                    "EraTestnetVerifier.sol",
                    abi.encode(verifierFflonk, verifierPlonk),
                    innerConfig
                );
            }
        } else {
            if (_isZKsyncOS) {
                _deployedContracts.stateTransition.verifier = _deployInternal(
                    "ZKsyncOSDualVerifier",
                    "ZKsyncOSDualVerifier.sol",
                    abi.encode(verifierFflonk, verifierPlonk, _verifierOwner),
                    innerConfig
                );
            } else {
                _deployedContracts.stateTransition.verifier = _deployInternal(
                    "EraDualVerifier",
                    "EraDualVerifier.sol",
                    abi.encode(verifierFflonk, verifierPlonk),
                    innerConfig
                );
            }
        }
        return _deployedContracts;
    }

    function _deployRollupDAManager(
        bytes32 _salt,
        address _governanceAddress,
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (DeployedContracts memory, address) {
        address daManager = _deployInternal("RollupDAManager", "RollupDAManager.sol", hex"", innerConfig);

        address validiumDAValidator = _deployInternal(
            "ValidiumL1DAValidator",
            "ValidiumL1DAValidator.sol",
            hex"",
            innerConfig
        );

        address relayedSLDAValidator = _deployInternal(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            hex"",
            innerConfig
        );

        _deployedContracts.daContracts.rollupDAManager = daManager;
        _deployedContracts.daContracts.relayedSLDAValidator = relayedSLDAValidator;
        _deployedContracts.daContracts.validiumDAValidator = validiumDAValidator;

        return (_deployedContracts, daManager);
    }

    function _deployCTM(
        bytes32 _salt,
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (DeployedContracts memory) {
        if (_config.isZKsyncOS) {
            _deployedContracts.stateTransition.chainTypeManagerImplementation = _deployInternal(
                "ZKsyncOSChainTypeManager",
                "ZKsyncOSChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR),
                innerConfig
            );
        } else {
            _deployedContracts.stateTransition.chainTypeManagerImplementation = _deployInternal(
                "EraChainTypeManager",
                "EraChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR),
                innerConfig
            );
        }

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.executorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(_deployedContracts.stateTransition.verifier),
            verifierParams: _config.verifierParams,
            l2BootloaderBytecodeHash: _config.bootloaderHash,
            l2DefaultAccountBytecodeHash: _config.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: _config.evmEmulatorHash,
            priorityTxMaxGasLimit: _config.priorityTxMaxGasLimit,
            feeParams: _config.feeParams
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: _deployedContracts.stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        _deployedContracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: _deployedContracts.stateTransition.genesisUpgrade,
            genesisBatchHash: _config.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(_config.genesisRollupLeafIndex),
            genesisBatchCommitment: _config.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: _config.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: _config.aliasedGovernanceAddress,
            validatorTimelock: _deployedContracts.stateTransition.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: _config.protocolVersion,
            serverNotifier: _deployedContracts.stateTransition.serverNotifierProxy
        });

        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));

        _deployedContracts.stateTransition.chainTypeManagerProxy = _deployInternal(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                _deployedContracts.stateTransition.chainTypeManagerImplementation,
                _deployedContracts.stateTransition.chainTypeManagerProxyAdmin,
                initCalldata
            ),
            innerConfig
        );

        return _deployedContracts;
    }

    function _deployInternal(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (address) {
        bytes memory bytecode = Utils.readZKFoundryBytecodeL1(fileName, contractName);

        return
            L2ContractHelper.computeCreate2Address(
                config.deployerAddr,
                config.salt,
                L2ContractHelper.hashL2Bytecode(bytecode),
                keccak256(params)
            );
    }

    /// @notice List of factory dependencies needed for the correct execution of
    /// CTMDeployer and healthy functionaling of the system overall
    function getListOfFactoryDeps() external returns (bytes[] memory dependencies) {
        uint256 totalDependencies = 25;
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
        // Include all verifiers since we cannot determine which one will be used
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierFflonk.sol", "EraVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierPlonk.sol", "EraVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierFflonk.sol", "ZKsyncOSVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraTestnetVerifier.sol", "EraTestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraDualVerifier.sol", "EraDualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSDualVerifier.sol", "ZKsyncOSDualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "ZKsyncOSChainTypeManager.sol",
            "ZKsyncOSChainTypeManager"
        );
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraChainTypeManager.sol", "EraChainTypeManager");
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
