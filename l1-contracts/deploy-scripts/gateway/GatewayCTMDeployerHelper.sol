// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Utils} from "../Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {
    DeployedContracts,
    GatewayCTMDeployerConfig,
    GatewayStep0_Multicall3,
    GatewayStep1_DA,
    GatewayStep2_FacetsAndUpgrades,
    GatewayStep3_Verifiers,
    GatewayStep4_ProxyAdmin,
    GatewayStep5_ValidatorTimelock,
    GatewayStep6_CTMAndServerNotifier
} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";

import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";

import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "contracts/state-transition/data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";

// solhint-disable gas-custom-errors
struct InnerDeployConfig {
    address deployerAddr;
    bytes32 salt;
}

library GatewayCTMDeployerHelper {
    // ============================================================
    // Legacy API (unchanged) - zkSync Era Create2Factory style
    // ============================================================

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

        contracts.stateTransition.chainTypeManagerProxyAdmin = _deployInternal("ProxyAdmin", "ProxyAdmin.sol", hex"", innerConfig);

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

        contracts.stateTransition.serverNotifierProxy = _deployServerNotifier(contracts, innerConfig, ctmDeployerAddress);

        // reuse shared init building
        (contracts.diamondCutData, bytes memory initCalldata) = _buildCtmInitData(config, contracts);

        // deploy CTM impl
        if (config.isZKsyncOS) {
            contracts.stateTransition.chainTypeManagerImplementation = _deployInternal(
                "ZKsyncOSChainTypeManager",
                "ZKsyncOSChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR),
                innerConfig
            );
        } else {
            contracts.stateTransition.chainTypeManagerImplementation = _deployInternal(
                "EraChainTypeManager",
                "EraChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR),
                innerConfig
            );
        }

        contracts.stateTransition.chainTypeManagerProxy = _deployInternal(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                contracts.stateTransition.chainTypeManagerImplementation,
                contracts.stateTransition.chainTypeManagerProxyAdmin,
                initCalldata
            ),
            innerConfig
        );
    }

    function _deployServerNotifier(
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig,
        address ctmDeployerAddress
    ) internal returns (address) {
        address serverNotifierImplementation = _deployInternal("ServerNotifier", "ServerNotifier.sol", abi.encode(), innerConfig);
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

        _deployedContracts.stateTransition.gettersFacet = _deployInternal("GettersFacet", "Getters.sol", hex"", innerConfig);

        address rollupDAManager;
        (_deployedContracts, rollupDAManager) = _deployRollupDAManager(_salt, _governanceAddress, _deployedContracts, innerConfig);

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
        _deployedContracts.stateTransition.genesisUpgrade = _deployInternal("L1GenesisUpgrade", "L1GenesisUpgrade.sol", hex"", innerConfig);

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
            verifierFflonk = _deployInternal("ZKsyncOSVerifierFflonk", "ZKsyncOSVerifierFflonk.sol", hex"", innerConfig);
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
        bytes32,
        address,
        DeployedContracts memory _deployedContracts,
        InnerDeployConfig memory innerConfig
    ) internal returns (DeployedContracts memory, address) {
        address daManager = _deployInternal("RollupDAManager", "RollupDAManager.sol", hex"", innerConfig);
        address validiumDAValidator = _deployInternal("ValidiumL1DAValidator", "ValidiumL1DAValidator.sol", hex"", innerConfig);
        address relayedSLDAValidator = _deployInternal("RelayedSLDAValidator", "RelayedSLDAValidator.sol", hex"", innerConfig);

        _deployedContracts.daContracts.rollupDAManager = daManager;
        _deployedContracts.daContracts.relayedSLDAValidator = relayedSLDAValidator;
        _deployedContracts.daContracts.validiumDAValidator = validiumDAValidator;

        return (_deployedContracts, daManager);
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

    // ============================================================
    // NEW: stepped deployment planner (zkSyncOS/EVM create2 style)
    // ============================================================

    struct SteppedDeploymentPlan {
        bytes32 outerSalt;
        address outerFactory;

        // initcodes for step contracts (constructor args already appended)
        bytes step0InitCode;
        bytes step1InitCode;
        bytes step2InitCode;
        bytes step3InitCode;
        bytes step4InitCode;
        bytes step5InitCode;
        bytes step6InitCode;
    }

    function buildSteppedDeployment(
        bytes32 outerSalt,
        GatewayCTMDeployerConfig memory cfg,
        address outerFactory
    ) internal pure returns (DeployedContracts memory contracts, SteppedDeploymentPlan memory plan) {
        plan.outerSalt = outerSalt;
        plan.outerFactory = outerFactory;

        // Step0
        plan.step0InitCode = abi.encodePacked(type(GatewayStep0_Multicall3).creationCode, abi.encode(cfg.salt));
        address step0Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step0InitCode));

        contracts.multicall3 = _evmCreate2(step0Addr, cfg.salt, keccak256(type(Multicall3).creationCode));

        // Step1
        plan.step1InitCode = abi.encodePacked(type(GatewayStep1_DA).creationCode, abi.encode(cfg.salt, cfg.aliasedGovernanceAddress));
        address step1Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step1InitCode));

        contracts.daContracts.rollupDAManager = _evmCreate2(step1Addr, cfg.salt, keccak256(type(RollupDAManager).creationCode));
        contracts.daContracts.validiumDAValidator = _evmCreate2(step1Addr, cfg.salt, keccak256(type(ValidiumL1DAValidator).creationCode));
        contracts.daContracts.relayedSLDAValidator = _evmCreate2(step1Addr, cfg.salt, keccak256(type(RelayedSLDAValidator).creationCode));

        // Step2
        plan.step2InitCode = abi.encodePacked(
            type(GatewayStep2_FacetsAndUpgrades).creationCode,
            abi.encode(cfg.salt, cfg.eraChainId, cfg.l1ChainId, contracts.daContracts.rollupDAManager, cfg.isZKsyncOS)
        );
        address step2Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step2InitCode));

        contracts.stateTransition.mailboxFacet = _evmCreate2(
            step2Addr,
            cfg.salt,
            keccak256(abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(cfg.eraChainId, cfg.l1ChainId)))
        );
        contracts.stateTransition.executorFacet = _evmCreate2(
            step2Addr,
            cfg.salt,
            keccak256(abi.encodePacked(type(ExecutorFacet).creationCode, abi.encode(cfg.l1ChainId)))
        );
        contracts.stateTransition.gettersFacet = _evmCreate2(step2Addr, cfg.salt, keccak256(type(GettersFacet).creationCode));
        contracts.stateTransition.adminFacet = _evmCreate2(
            step2Addr,
            cfg.salt,
            keccak256(abi.encodePacked(type(AdminFacet).creationCode, abi.encode(cfg.l1ChainId, contracts.daContracts.rollupDAManager)))
        );

        contracts.stateTransition.diamondInit = _evmCreate2(
            step2Addr,
            cfg.salt,
            keccak256(abi.encodePacked(type(DiamondInit).creationCode, abi.encode(cfg.isZKsyncOS)))
        );
        contracts.stateTransition.genesisUpgrade = _evmCreate2(step2Addr, cfg.salt, keccak256(type(L1GenesisUpgrade).creationCode));

        // Step3
        plan.step3InitCode = abi.encodePacked(
            type(GatewayStep3_Verifiers).creationCode,
            abi.encode(cfg.salt, cfg.testnetVerifier, cfg.isZKsyncOS, cfg.aliasedGovernanceAddress)
        );
        address step3Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step3InitCode));

        if (cfg.isZKsyncOS) {
            contracts.stateTransition.verifierFflonk = _evmCreate2(step3Addr, cfg.salt, keccak256(type(ZKsyncOSVerifierFflonk).creationCode));
            contracts.stateTransition.verifierPlonk = _evmCreate2(step3Addr, cfg.salt, keccak256(type(ZKsyncOSVerifierPlonk).creationCode));

            if (cfg.testnetVerifier) {
                contracts.stateTransition.verifier = _evmCreate2(
                    step3Addr,
                    cfg.salt,
                    keccak256(
                        abi.encodePacked(
                            type(ZKsyncOSTestnetVerifier).creationCode,
                            abi.encode(IVerifierV2(contracts.stateTransition.verifierFflonk), IVerifier(contracts.stateTransition.verifierPlonk), cfg.aliasedGovernanceAddress)
                        )
                    )
                );
            } else {
                contracts.stateTransition.verifier = _evmCreate2(
                    step3Addr,
                    cfg.salt,
                    keccak256(
                        abi.encodePacked(
                            type(ZKsyncOSDualVerifier).creationCode,
                            abi.encode(IVerifierV2(contracts.stateTransition.verifierFflonk), IVerifier(contracts.stateTransition.verifierPlonk), cfg.aliasedGovernanceAddress)
                        )
                    )
                );
            }
        } else {
            contracts.stateTransition.verifierFflonk = _evmCreate2(step3Addr, cfg.salt, keccak256(type(EraVerifierFflonk).creationCode));
            contracts.stateTransition.verifierPlonk = _evmCreate2(step3Addr, cfg.salt, keccak256(type(EraVerifierPlonk).creationCode));

            if (cfg.testnetVerifier) {
                contracts.stateTransition.verifier = _evmCreate2(
                    step3Addr,
                    cfg.salt,
                    keccak256(
                        abi.encodePacked(
                            type(EraTestnetVerifier).creationCode,
                            abi.encode(IVerifierV2(contracts.stateTransition.verifierFflonk), IVerifier(contracts.stateTransition.verifierPlonk))
                        )
                    )
                );
            } else {
                contracts.stateTransition.verifier = _evmCreate2(
                    step3Addr,
                    cfg.salt,
                    keccak256(
                        abi.encodePacked(
                            type(EraDualVerifier).creationCode,
                            abi.encode(IVerifierV2(contracts.stateTransition.verifierFflonk), IVerifier(contracts.stateTransition.verifierPlonk))
                        )
                    )
                );
            }
        }

        // Step4 (ProxyAdmin)
        plan.step4InitCode = abi.encodePacked(type(GatewayStep4_ProxyAdmin).creationCode, abi.encode(cfg.salt, cfg.aliasedGovernanceAddress));
        address step4Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step4InitCode));

        contracts.stateTransition.chainTypeManagerProxyAdmin = _evmCreate2(step4Addr, cfg.salt, keccak256(type(ProxyAdmin).creationCode));

        // Step5 (ValidatorTimelock)
        plan.step5InitCode = abi.encodePacked(
            type(GatewayStep5_ValidatorTimelock).creationCode,
            abi.encode(cfg.salt, contracts.stateTransition.chainTypeManagerProxyAdmin, cfg.aliasedGovernanceAddress)
        );
        address step5Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step5InitCode));

        contracts.stateTransition.validatorTimelockImplementation = _evmCreate2(
            step5Addr,
            cfg.salt,
            keccak256(abi.encodePacked(type(ValidatorTimelock).creationCode, abi.encode(L2_BRIDGEHUB_ADDR)))
        );
        contracts.stateTransition.validatorTimelock = _evmCreate2(
            step5Addr,
            cfg.salt,
            keccak256(
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(
                        contracts.stateTransition.validatorTimelockImplementation,
                        contracts.stateTransition.chainTypeManagerProxyAdmin,
                        abi.encodeCall(ValidatorTimelock.initialize, (cfg.aliasedGovernanceAddress, 0))
                    )
                )
            )
        );

        // Step6 (ServerNotifier + CTM + wiring)
        plan.step6InitCode = abi.encodePacked(
            type(GatewayStep6_CTMAndServerNotifier).creationCode,
            abi.encode(
                cfg.salt,
                cfg,
                contracts.stateTransition.chainTypeManagerProxyAdmin,
                step2Addr,
                step3Addr,
                step5Addr
            )
        );
        address step6Addr = _evmCreate2(outerFactory, outerSalt, keccak256(plan.step6InitCode));

        contracts.stateTransition.serverNotifierImplementation = _evmCreate2(step6Addr, cfg.salt, keccak256(type(ServerNotifier).creationCode));
        contracts.stateTransition.serverNotifierProxy = _evmCreate2(
            step6Addr,
            cfg.salt,
            keccak256(
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(
                        contracts.stateTransition.serverNotifierImplementation,
                        contracts.stateTransition.chainTypeManagerProxyAdmin,
                        abi.encodeCall(ServerNotifier.initialize, (step6Addr))
                    )
                )
            )
        );

        // CTM impl
        if (cfg.isZKsyncOS) {
            contracts.stateTransition.chainTypeManagerImplementation = _evmCreate2(
                step6Addr,
                cfg.salt,
                keccak256(abi.encodePacked(type(ZKsyncOSChainTypeManager).creationCode, abi.encode(L2_BRIDGEHUB_ADDR)))
            );
        } else {
            contracts.stateTransition.chainTypeManagerImplementation = _evmCreate2(
                step6Addr,
                cfg.salt,
                keccak256(abi.encodePacked(type(EraChainTypeManager).creationCode, abi.encode(L2_BRIDGEHUB_ADDR)))
            );
        }

        // Build diamondCutData + CTM init calldata (shared with legacy)
        (contracts.diamondCutData, bytes memory initCalldata) = _buildCtmInitData(cfg, contracts);

        // CTM proxy
        contracts.stateTransition.chainTypeManagerProxy = _evmCreate2(
            step6Addr,
            cfg.salt,
            keccak256(
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(
                        contracts.stateTransition.chainTypeManagerImplementation,
                        contracts.stateTransition.chainTypeManagerProxyAdmin,
                        initCalldata
                    )
                )
            )
        );

        return (contracts, plan);
    }

    function _evmCreate2(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    // ============================================================
    // Shared init building (reduces duplication)
    // ============================================================

    function _buildCtmInitData(
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts
    ) private pure returns (bytes memory diamondCutData, bytes memory initCalldata) {
        Diamond.FacetCut;
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

        diamondCutData = abi.encode(diamondCut);

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

        initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));
    }

    // ============================================================
    // Factory deps lists
    // ============================================================

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
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierFflonk.sol", "EraVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierPlonk.sol", "EraVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierFflonk.sol", "ZKsyncOSVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraTestnetVerifier.sol", "EraTestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraDualVerifier.sol", "EraDualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSDualVerifier.sol", "ZKsyncOSDualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSChainTypeManager.sol", "ZKsyncOSChainTypeManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraChainTypeManager.sol", "EraChainTypeManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("TransparentUpgradeableProxy.sol", "TransparentUpgradeableProxy");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondProxy.sol", "DiamondProxy");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier");

        return dependencies;
    }

    function getListOfFactoryDepsStepped() external returns (bytes[] memory dependencies) {
        // legacy deps + step wrappers + missing verifier wrapper
        uint256 totalDependencies = 33;
        dependencies = new bytes[](totalDependencies);
        uint256 index = 0;

        // Step wrappers (assumed to live in GatewayCTMDeployer.sol)
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep0_Multicall3");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep1_DA");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep2_FacetsAndUpgrades");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep3_Verifiers");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep4_ProxyAdmin");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep5_ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployer.sol", "GatewayStep6_CTMAndServerNotifier");

        // Inner deps (mostly same as legacy)
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

        // Verifiers
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierFflonk.sol", "EraVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierPlonk.sol", "EraVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierFflonk.sol", "ZKsyncOSVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraTestnetVerifier.sol", "EraTestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSTestnetVerifier.sol", "ZKsyncOSTestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraDualVerifier.sol", "EraDualVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSDualVerifier.sol", "ZKsyncOSDualVerifier");

        // Proxies / CTM / Notifier / Timelock
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ZKsyncOSChainTypeManager.sol", "ZKsyncOSChainTypeManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraChainTypeManager.sol", "EraChainTypeManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("TransparentUpgradeableProxy.sol", "TransparentUpgradeableProxy");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondProxy.sol", "DiamondProxy");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier");

        return dependencies;
    }
}
