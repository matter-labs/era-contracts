// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";
import {console2 as console} from "forge-std/Script.sol";

import {ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";

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
import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";

import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {DeployUtils} from "../utils/deploy/DeployUtils.sol";
import {CTMContract} from "./DeployCTML1OrGateway.sol";
import {ChainCreationParamsLib} from "./ChainCreationParamsLib.sol";

import {
    StateTransitionDeployedAddresses,
    DataAvailabilityDeployedAddresses,
    ChainCreationParamsConfig,
    BridgehubAddresses,
    CoreDeployedAddresses
} from "../utils/Types.sol";
import {CTMContract, CTMCoreDeploymentConfig, DeployCTML1OrGateway} from "./DeployCTML1OrGateway.sol";

import {CTMDeployedAddresses} from "../utils/Types.sol";

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 gatewayChainId;
    address ownerAddress;
    bytes32 zkTokenAssetId;
    bool testnetVerifier;
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
    /// @dev Deployed together with the v32 upgrade contract (see `CTMUpgrade_v31`), which embeds
    /// it as an immutable.
    address internal priorityOpLowerBound;

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
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet");
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet");
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet");
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet");
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet");
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet");
        ctmAddresses.stateTransition.facets.diamondInit = deploySimpleContract("DiamondInit");
    }

    function initializeConfig(string memory configPath, address bridgehub) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = getBroadcasterAddress();

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

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
        config.contracts.chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath());

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal virtual returns (ChainCreationParamsConfig memory chainCreationParams) {
        return ChainCreationParamsLib.getChainCreationParams(_config);
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

        require(stateTransition.verifiers.verifier != address(0), "verifier is zero");

        // ZKsync OS has no bootloader, default-account or EVM-emulator bytecode; `DiamondInit` skips
        // its non-zero checks for OS chains and never reads the slots back.
        // TODO: drop these three fields from `InitializeDataNewChain` in the next release; the struct
        // is part of the frozen `DiamondInit` ABI, so they cannot go here.
        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            l2BootloaderBytecodeHash: bytes32(0),
            l2DefaultAccountBytecodeHash: bytes32(0),
            l2EvmEmulatorBytecodeHash: bytes32(0)
        });

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

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getRollupL2DACommitmentScheme() internal returns (L2DACommitmentScheme) {
        return ROLLUP_L2_DA_COMMITMENT_SCHEME;
    }

    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "EIP7702Checker")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.daContracts.rollupSLDAValidator);
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.availBridge);
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ZKsyncOSVerifierPlonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgradeZKsyncOS")) {
            return abi.encode();
        } else if (compareStrings(contractName, "V32UpgradeZKsyncOS")) {
            // The v32 upgrade contract pins the priority-op lower-bound registry as an immutable.
            require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");
            return abi.encode(priorityOpLowerBound);
        } else if (compareStrings(contractName, "PriorityOpLowerBound")) {
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
        } else if (compareStrings(contractName, "MultisigCommitter")) {
            // Same constructor as ValidatorTimelock (it derives from it): the bridgehub immutable.
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub);
        } else {
            return
                DeployCTML1OrGateway.getCreationCalldata(
                    getCTMCoreDeploymentConfig(config),
                    DeployCTML1OrGateway.getCTMContractFromName(contractName)
                );
        }
    }

    function getCTMCoreDeploymentConfig(Config memory _config) internal view returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                testnetVerifier: _config.testnetVerifier,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: coreAddresses.bridgehub.proxies.bridgehub,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: ctmAddresses.daAddresses.daContracts.rollupDAManager,
                chainAssetHandler: coreAddresses.bridgehub.proxies.chainAssetHandler,
                l1BytecodesSupplier: ctmAddresses.stateTransition.proxies.bytecodesSupplier,
                eip7702Checker: ctmAddresses.admin.eip7702Checker,
                verifierFflonk: ctmAddresses.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: ctmAddresses.stateTransition.verifiers.verifierPlonk,
                permissionlessValidator: ctmAddresses.stateTransition.proxies.permissionlessValidator
            });
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
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
        } else if (compareStrings(contractName, "MultisigCommitter")) {
            // `initializeV2`, not the inherited `initialize`: a fresh proxy has to land at
            // `_initialized = 2` with the EIP-712 domain set, matching one that got there via
            // `reinitializeV2` during the v31 upgrade.
            return
                abi.encodeCall(
                    MultisigCommitter.initializeV2,
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
