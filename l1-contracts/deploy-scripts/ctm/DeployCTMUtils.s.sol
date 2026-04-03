// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";
import {console2 as console} from "forge-std/Script.sol";

import {ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";
// Verifier lifecycle is now handled through EraZkosRouter

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";

import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";

import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {DeployUtils} from "../utils/deploy/DeployUtils.sol";
import {EraZkosRouter, EraZkosContract} from "../utils/EraZkosRouter.sol";

import {
    StateTransitionDeployedAddresses,
    DataAvailabilityDeployedAddresses,
    ChainCreationParamsConfig,
    BridgehubAddresses,
    CoreDeployedAddresses
} from "../utils/Types.sol";
import {CTMContract, CTMCoreDeploymentConfig, DeployCTML1OrGateway} from "./DeployCTML1OrGateway.sol";

import {CTMDeployedAddresses} from "../utils/Types.sol";
import {SettlementLayerV31Upgrade} from "contracts/upgrades/SettlementLayerV31Upgrade.sol";

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 eraChainId;
    uint256 gatewayChainId;
    address ownerAddress;
    bytes32 zkTokenAssetId;
    bool testnetVerifier;
    bool supportL2LegacySharedBridgeTest;
    bool isZKsyncOS;
    ContractsConfig contracts;
}

// solhint-disable-next-line gas-struct-packing
struct ContractsConfig {
    address multicall3Addr;
    uint256 validatorTimelockExecutionDelay;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    bytes diamondCutData;
    uint256 maxNumberOfChains;
    // questionable
    address availL1DAValidator;
    ChainCreationParamsConfig chainCreationParams;
}

// solhint-disable-next-line gas-struct-packing
struct GeneratedData {
    bytes forceDeploymentsData;
}

abstract contract DeployCTMUtils is DeployUtils {
    using stdToml for string;

    Config public config;
    // Note: This variable is initialized by concrete implementations before use
    GeneratedData internal generatedData; //slither-disable-line uninitialized-state
    CTMDeployedAddresses internal ctmAddresses;
    // Note: Addresses discovered from already deployed core contracts (Bridgehub, AssetRouter, etc.)
    // This variable is initialized by concrete implementations before use
    CoreDeployedAddresses internal coreAddresses; //slither-disable-line uninitialized-state

    //slither-disable-next-line reentrancy-benign
    function deployStateTransitionDiamondFacets() internal {
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet", false);
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet", false);
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet", false);
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet", false);
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet", false);
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet", false);
        ctmAddresses.stateTransition.facets.diamondInit = deploySimpleContract("DiamondInit", false);
    }

    function chainCreationParamsPath(bool _isZKsyncOS) internal virtual returns (string memory) {
        return EraZkosRouter.genesisConfigPath(_isZKsyncOS);
    }

    function initializeConfig(
        string memory configPath,
        string memory permanentValuesPath,
        address bridgehub
    ) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = getBroadcasterAddress();

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

        config.supportL2LegacySharedBridgeTest = toml.readBool("$.support_l2_legacy_shared_bridge_test");
        if (toml.keyExists("$.is_zk_sync_os")) {
            config.isZKsyncOS = toml.readBool("$.is_zk_sync_os");
        }
        if (toml.keyExists("$.zk_token_asset_id")) {
            config.zkTokenAssetId = toml.readBytes32("$.zk_token_asset_id");
        }
        require(config.zkTokenAssetId != bytes32(0), "zk_token_asset_id must be non-zero in config");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");

        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.chainCreationParams = getChainCreationParamsConfig(
            EraZkosRouter.genesisConfigPath(config.isZKsyncOS)
        );

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal virtual returns (ChainCreationParamsConfig memory chainCreationParams) {
        return EraZkosRouter.getChainCreationParams(config.isZKsyncOS, _config);
    }

    /// @notice Get all six facet cuts
    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new Diamond.FacetCut[](6);
        facetCuts[0] = Diamond.FacetCut({
            facet: stateTransition.facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: stateTransition.facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: stateTransition.facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: stateTransition.facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.executorFacet.code)
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: stateTransition.facets.migratorFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.migratorFacet.code)
        });
        facetCuts[5] = Diamond.FacetCut({
            facet: stateTransition.facets.committerFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(ctmAddresses.stateTransition.facets.committerFacet.code)
        });
    }

    function getChainCreationDiamondCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (Diamond.DiamondCutData memory diamondCut) {
        Diamond.FacetCut[] memory facetCuts = getChainCreationFacetCuts(stateTransition);

        DiamondInitializeDataNewChain memory initializeData = getInitializeData(stateTransition);

        diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.facets.diamondInit,
            initCalldata: abi.encode(initializeData)
        });
    }

    function getChainCreationParams(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainCreationParams memory) {
        require(generatedData.forceDeploymentsData.length != 0, "force deployments data is empty");
        Diamond.DiamondCutData memory diamondCut = getChainCreationDiamondCutData(stateTransition);
        config.contracts.diamondCutData = abi.encode(diamondCut);
        return
            ChainCreationParams({
                genesisUpgrade: stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
                genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
                diamondCut: diamondCut,
                forceDeploymentsData: generatedData.forceDeploymentsData
            });
    }

    function getChainTypeManagerInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainTypeManagerInitializeData memory) {
        ChainCreationParams memory chainCreationParams = getChainCreationParams(stateTransition);
        return
            ChainTypeManagerInitializeData({
                owner: getBroadcasterAddress(),
                validatorTimelock: stateTransition.proxies.validatorTimelock,
                chainCreationParams: chainCreationParams,
                protocolVersion: config.contracts.chainCreationParams.latestProtocolVersion,
                verifier: stateTransition.verifiers.verifier,
                serverNotifier: stateTransition.proxies.serverNotifier
            });
    }

    function getInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (DiamondInitializeDataNewChain memory) {
        require(stateTransition.verifiers.verifier != address(0), "verifier is zero");
        if (!config.isZKsyncOS) {
            require(config.contracts.chainCreationParams.bootloaderHash != bytes32(0), "bootloader hash is zero");
            require(
                config.contracts.chainCreationParams.defaultAAHash != bytes32(0),
                "default account abstraction hash is zero"
            );
            require(config.contracts.chainCreationParams.evmEmulatorHash != bytes32(0), "EVM emulator hash is zero");
        }

        return
            DiamondInitializeDataNewChain({
                l2BootloaderBytecodeHash: config.contracts.chainCreationParams.bootloaderHash,
                l2DefaultAccountBytecodeHash: config.contracts.chainCreationParams.defaultAAHash,
                l2EvmEmulatorBytecodeHash: config.contracts.chainCreationParams.evmEmulatorHash
            });
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            return ContractsBytecodesLib.getCreationCodeEVM(contractName);
        }
        return ContractsBytecodesLib.getL2Bytecode(contractName, config.isZKsyncOS);
    }

    function getRollupL2DACommitmentScheme() internal returns (L2DACommitmentScheme) {
        return ROLLUP_L2_DA_COMMITMENT_SCHEME;
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "EIP7702Checker")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.l1RollupDAValidator);
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.availBridge);
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return abi.encode();
        } else if (
            compareStrings(contractName, "EraVerifierFflonk") || compareStrings(contractName, "ZKsyncOSVerifierFflonk")
        ) {
            return abi.encode();
        } else if (
            compareStrings(contractName, "EraVerifierPlonk") || compareStrings(contractName, "ZKsyncOSVerifierPlonk")
        ) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "SettlementLayerV31Upgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "Governance")) {
            return
                abi.encode(
                    config.ownerAddress,
                    config.contracts.governanceSecurityCouncilAddress,
                    config.contracts.governanceMinDelay
                );
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return abi.encode(config.ownerAddress, address(0));
        } else if (compareStrings(contractName, "AccessControlRestriction")) {
            return abi.encode(uint256(0), config.ownerAddress);
        } else if (compareStrings(contractName, "ChainAdmin")) {
            address[] memory restrictions = new address[](1);
            restrictions[0] = ctmAddresses.admin.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "PermissionlessValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();
        } else if (compareStrings(contractName, "GettersFacet")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1AssetTracker")) {
            return
                abi.encode(
                    config.l1ChainId,
                    coreAddresses.bridgehub.proxies.bridgehub,
                    coreAddresses.bridges.proxies.l1AssetRouter,
                    coreAddresses.bridges.proxies.l1NativeTokenVault,
                    coreAddresses.bridgehub.proxies.messageRoot
                );
        } else {
            return
                DeployCTML1OrGateway.getCreationCalldata(
                    getCTMCoreDeploymentConfig(config),
                    config.isZKsyncOS,
                    DeployCTML1OrGateway.getCTMContractFromName(contractName),
                    isZKBytecode
                );
        }
    }

    function getCTMCoreDeploymentConfig(Config memory _config) internal view returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                isZKsyncOS: config.isZKsyncOS,
                testnetVerifier: _config.testnetVerifier,
                eraChainId: _config.eraChainId,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: coreAddresses.bridgehub.proxies.bridgehub,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: ctmAddresses.daAddresses.daContracts.rollupDAManager,
                chainAssetHandler: coreAddresses.bridgehub.proxies.chainAssetHandler,
                l1BytecodesSupplier: ctmAddresses.stateTransition.proxies.bytecodesSupplier,
                eip7702Checker: ctmAddresses.admin.eip7702Checker,
                verifierFflonk: ctmAddresses.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: ctmAddresses.stateTransition.verifiers.verifierPlonk,
                // For L1 deployment we need to use the deployer as the owner of the verifier,
                // because we set the dual verifier later. Use getBroadcasterAddress() to get
                // the actual EOA when this is called from a contract created via `new` during the script.
                verifierOwner: getBroadcasterAddress(),
                permissionlessValidator: ctmAddresses.stateTransition.proxies.permissionlessValidator
            });
    }

    function getL2BytecodeHash(string memory contractName) public view virtual returns (bytes32) {
        return L2ContractHelper.hashL2Bytecode(getCreationCode(contractName, true));
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "EraChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManagerBase.initialize,
                    getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManagerBase.initialize,
                    getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encodeCall(ServerNotifier.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return
                abi.encodeCall(
                    ValidatorTimelock.initialize,
                    (config.deployerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                );
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encodeCall(BytecodesSupplier.initialize, ());
        } else if (compareStrings(contractName, "PermissionlessValidator")) {
            return abi.encodeCall(PermissionlessValidator.initialize, ());
        } else {
            revert(string.concat("Contract ", contractName, " initialize calldata not set"));
        }
    }

    function transparentProxyAdmin() internal view override returns (address) {
        return ctmAddresses.admin.transparentProxyAdmin;
    }

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }

    function test() internal virtual {}
}
