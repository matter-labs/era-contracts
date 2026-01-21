// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DefaultEcosystemUpgrade} from "./DefaultEcosystemUpgrade.s.sol";
import {StateTransitionDeployedAddresses} from "../Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {Bridgehub, IBridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Call} from "contracts/governance/Common.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

/// @notice Script for verifier-only upgrade
/// @dev This script only redeploys the verifier and updates the chain creation params.
/// It doesn't update any other facets or contracts.
contract VerifierOnlyUpgrade is DefaultEcosystemUpgrade {
    using stdToml for string;

    /// @notice Old chain creation params read from input
    struct OldChainCreationParamsInput {
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes32 genesisBatchCommitment;
        bytes diamondCutData;
        bytes forceDeploymentsData;
    }

    /// @notice Old chain creation params for L1
    OldChainCreationParamsInput internal oldL1ChainCreationParams;

    /// @notice Old chain creation params for Gateway
    OldChainCreationParamsInput internal oldGWChainCreationParams;

    function initialize(string memory newConfigPath, string memory _outputPath) public virtual override {
        super.initialize(newConfigPath, _outputPath);

        // Read old chain creation params from input
        string memory root = vm.projectRoot();
        string memory toml = vm.readFile(string.concat(root, newConfigPath));

        _readOldChainCreationParams(toml);
        _verifyChainCreationParamsHash();
    }

    /// @notice Read old chain creation params from input TOML
    function _readOldChainCreationParams(string memory toml) internal {
        // Read L1 old chain creation params
        oldL1ChainCreationParams.genesisUpgrade = toml.readAddress(
            "$.old_chain_creation_params.l1.genesis_upgrade"
        );
        oldL1ChainCreationParams.genesisBatchHash = toml.readBytes32(
            "$.old_chain_creation_params.l1.genesis_batch_hash"
        );
        oldL1ChainCreationParams.genesisIndexRepeatedStorageChanges = uint64(
            toml.readUint("$.old_chain_creation_params.l1.genesis_index_repeated_storage_changes")
        );
        oldL1ChainCreationParams.genesisBatchCommitment = toml.readBytes32(
            "$.old_chain_creation_params.l1.genesis_batch_commitment"
        );
        oldL1ChainCreationParams.diamondCutData = toml.readBytes(
            "$.old_chain_creation_params.l1.diamond_cut_data"
        );
        oldL1ChainCreationParams.forceDeploymentsData = toml.readBytes(
            "$.old_chain_creation_params.l1.force_deployments_data"
        );

        // Read Gateway old chain creation params if gateway chain id is set
        if (gatewayConfig.chainId != 0) {
            oldGWChainCreationParams.genesisUpgrade = toml.readAddress(
                "$.old_chain_creation_params.gateway.genesis_upgrade"
            );
            oldGWChainCreationParams.genesisBatchHash = toml.readBytes32(
                "$.old_chain_creation_params.gateway.genesis_batch_hash"
            );
            oldGWChainCreationParams.genesisIndexRepeatedStorageChanges = uint64(
                toml.readUint("$.old_chain_creation_params.gateway.genesis_index_repeated_storage_changes")
            );
            oldGWChainCreationParams.genesisBatchCommitment = toml.readBytes32(
                "$.old_chain_creation_params.gateway.genesis_batch_commitment"
            );
            oldGWChainCreationParams.diamondCutData = toml.readBytes(
                "$.old_chain_creation_params.gateway.diamond_cut_data"
            );
            oldGWChainCreationParams.forceDeploymentsData = toml.readBytes(
                "$.old_chain_creation_params.gateway.force_deployments_data"
            );
        }
    }

    /// @notice Verify that the old chain creation params match the stored hash in CTM
    function _verifyChainCreationParamsHash() internal view {
        // Verify L1 chain creation params
        ChainTypeManager ctm = ChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);

        bytes32 expectedInitialCutHash = ctm.initialCutHash();
        bytes32 actualInitialCutHash = keccak256(oldL1ChainCreationParams.diamondCutData);
        require(
            expectedInitialCutHash == actualInitialCutHash,
            "L1 diamond cut hash mismatch with CTM"
        );

        bytes32 expectedForceDeploymentHash = ctm.initialForceDeploymentHash();
        bytes32 actualForceDeploymentHash = keccak256(abi.encode(oldL1ChainCreationParams.forceDeploymentsData));
        require(
            expectedForceDeploymentHash == actualForceDeploymentHash,
            "L1 force deployment hash mismatch with CTM"
        );

        console.log("L1 chain creation params verified successfully");
    }

    /// @notice Only deploy verifiers, skip all other ecosystem contract deployments
    function deployNewEcosystemContractsL1() public virtual override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        // Only deploy verifiers
        deployVerifiers();
        deployUpgradeStageValidator();

        // Deploy the upgrade contract (DefaultUpgrade) for the upgrade call
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        addresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    /// @notice Only deploy verifiers for Gateway
    function deployNewEcosystemContractsGW() public virtual override {
        require(upgradeConfig.initialized, "Not initialized");

        if (gatewayConfig.chainId == 0) return;

        gatewayConfig.gatewayStateTransition.verifierFflonk = deployGWContract("VerifierFflonk");
        gatewayConfig.gatewayStateTransition.verifierPlonk = deployGWContract("VerifierPlonk");
        gatewayConfig.gatewayStateTransition.verifier = deployGWContract("Verifier");

        gatewayConfig.gatewayStateTransition.defaultUpgrade = deployUsedUpgradeContractGW();
    }

    /// @notice Skip bytecode publishing as we don't have L2 upgrades
    function publishBytecodes() public virtual override {
        upgradeConfig.factoryDepsPublished = true;
    }

    /// @notice Generate upgrade data with only verifier
    function generateUpgradeData() public virtual override {
        require(upgradeConfig.initialized, "Not initialized");
        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Generate upgrade cut data with only verifier change
        generateUpgradeCutData(addresses.stateTransition);
        if (gatewayConfig.chainId != 0) {
            generateUpgradeCutData(gatewayConfig.gatewayStateTransition);
        }

        // Populate newlyGeneratedData with new chain creation params for compatibility with parent's saveOutput
        ChainCreationParams memory newL1ChainCreationParams = _getChainCreationParamsWithNewVerifier(addresses.stateTransition);
        newlyGeneratedData.diamondCutData = abi.encode(newL1ChainCreationParams.diamondCut);
        newlyGeneratedData.fixedForceDeploymentsData = newL1ChainCreationParams.forceDeploymentsData;

        // Populate gateway data if configured
        if (gatewayConfig.chainId != 0) {
            ChainCreationParams memory newGwChainCreationParams = _getChainCreationParamsWithNewVerifier(gatewayConfig.gatewayStateTransition);
            gatewayConfig.facetCutsData = abi.encode(newGwChainCreationParams.diamondCut);
        }

        upgradeConfig.upgradeCutPrepared = true;
        console.log("Upgrade cut generated");
        saveOutput(upgradeConfig.outputPath);

        // Save old chain creation params to output for verification
        _saveOldChainCreationParams();
    }

    /// @notice Save old chain creation params to output for verification
    function _saveOldChainCreationParams() internal {
        // Save L1 old chain creation params
        vm.serializeAddress(
            "old_chain_creation_params_l1",
            "genesis_upgrade",
            oldL1ChainCreationParams.genesisUpgrade
        );
        vm.serializeBytes32(
            "old_chain_creation_params_l1",
            "genesis_batch_hash",
            oldL1ChainCreationParams.genesisBatchHash
        );
        vm.serializeUint(
            "old_chain_creation_params_l1",
            "genesis_index_repeated_storage_changes",
            uint256(oldL1ChainCreationParams.genesisIndexRepeatedStorageChanges)
        );
        vm.serializeBytes32(
            "old_chain_creation_params_l1",
            "genesis_batch_commitment",
            oldL1ChainCreationParams.genesisBatchCommitment
        );
        vm.serializeBytes(
            "old_chain_creation_params_l1",
            "diamond_cut_data",
            oldL1ChainCreationParams.diamondCutData
        );
        string memory oldL1Params = vm.serializeBytes(
            "old_chain_creation_params_l1",
            "force_deployments_data",
            oldL1ChainCreationParams.forceDeploymentsData
        );

        vm.writeToml(oldL1Params, upgradeConfig.outputPath, ".old_chain_creation_params.l1");

        // Save Gateway old chain creation params if configured
        if (gatewayConfig.chainId != 0) {
            vm.serializeAddress(
                "old_chain_creation_params_gw",
                "genesis_upgrade",
                oldGWChainCreationParams.genesisUpgrade
            );
            vm.serializeBytes32(
                "old_chain_creation_params_gw",
                "genesis_batch_hash",
                oldGWChainCreationParams.genesisBatchHash
            );
            vm.serializeUint(
                "old_chain_creation_params_gw",
                "genesis_index_repeated_storage_changes",
                uint256(oldGWChainCreationParams.genesisIndexRepeatedStorageChanges)
            );
            vm.serializeBytes32(
                "old_chain_creation_params_gw",
                "genesis_batch_commitment",
                oldGWChainCreationParams.genesisBatchCommitment
            );
            vm.serializeBytes(
                "old_chain_creation_params_gw",
                "diamond_cut_data",
                oldGWChainCreationParams.diamondCutData
            );
            string memory oldGwParams = vm.serializeBytes(
                "old_chain_creation_params_gw",
                "force_deployments_data",
                oldGWChainCreationParams.forceDeploymentsData
            );

            vm.writeToml(oldGwParams, upgradeConfig.outputPath, ".old_chain_creation_params.gateway");
        }

        console.log("Old chain creation params saved to output");
    }

    /// @notice Get proposed upgrade with only verifier (everything else is empty/zero)
    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual override returns (ProposedUpgrade memory proposedUpgrade) {
        // Empty verifier params - will not update
        VerifierParams memory emptyVerifierParams = VerifierParams({
            recursionNodeLevelVkHash: bytes32(0),
            recursionLeafLevelVkHash: bytes32(0),
            recursionCircuitsSetVksHash: bytes32(0)
        });

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeEmptyUpgradeTx(),
            bootloaderHash: bytes32(0), // Will not update
            defaultAccountHash: bytes32(0), // Will not update
            evmEmulatorHash: bytes32(0), // Will not update
            verifier: stateTransition.verifier, // Only verifier is set
            verifierParams: emptyVerifierParams, // Will not update
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });
    }

    /// @notice Generate upgrade cut data - no facet changes, only verifier
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual override returns (Diamond.DiamondCutData memory upgradeCutData) {
        // No facet cuts - we're only updating the verifier
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(stateTransition);

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(
                DefaultUpgrade.upgrade,
                (proposedUpgrade)
            )
        });

        if (!stateTransition.isOnGateway) {
            newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
        } else {
            gatewayConfig.upgradeCutData = abi.encode(upgradeCutData);
        }
    }

    /// @notice Get chain creation params with new verifier but same everything else
    function _getChainCreationParamsWithNewVerifier(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal view returns (ChainCreationParams memory) {
        OldChainCreationParamsInput memory oldParams;

        if (!stateTransition.isOnGateway) {
            oldParams = oldL1ChainCreationParams;
        } else {
            oldParams = oldGWChainCreationParams;
        }

        // Decode the old diamond cut data
        Diamond.DiamondCutData memory oldDiamondCut = abi.decode(
            oldParams.diamondCutData,
            (Diamond.DiamondCutData)
        );

        // Decode the old init data and update only the verifier
        DiamondInitializeDataNewChain memory initData = abi.decode(
            oldDiamondCut.initCalldata,
            (DiamondInitializeDataNewChain)
        );

        // Update only the verifier
        initData.verifier = IVerifier(stateTransition.verifier);

        // Re-encode the diamond cut with the new verifier
        Diamond.DiamondCutData memory newDiamondCut = Diamond.DiamondCutData({
            facetCuts: oldDiamondCut.facetCuts,
            initAddress: oldDiamondCut.initAddress,
            initCalldata: abi.encode(initData)
        });

        return ChainCreationParams({
            genesisUpgrade: oldParams.genesisUpgrade,
            genesisBatchHash: oldParams.genesisBatchHash,
            genesisIndexRepeatedStorageChanges: oldParams.genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: oldParams.genesisBatchCommitment,
            diamondCut: newDiamondCut,
            forceDeploymentsData: oldParams.forceDeploymentsData
        });
    }

    /// @notice Override to use old chain creation params with new verifier
    function prepareNewChainCreationParamsCall() public virtual override returns (Call[] memory calls) {
        require(
            addresses.stateTransition.chainTypeManagerProxy != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                ChainTypeManager.setChainCreationParams,
                (_getChainCreationParamsWithNewVerifier(addresses.stateTransition))
            ),
            value: 0
        });
    }

    /// @notice Override to use old chain creation params with new verifier for Gateway
    function prepareNewChainCreationParamsCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual override returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setChainCreationParams,
            (_getChainCreationParamsWithNewVerifier(gatewayConfig.gatewayStateTransition))
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    /// @notice Stage 1 calls - only set chain creation params for L1 and GW
    function prepareStage1GovernanceCalls() public virtual override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);

        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        // Only set new chain creation params and version upgrade
        allCalls[2] = prepareNewChainCreationParamsCall();
        allCalls[3] = provideSetNewVersionUpgradeCall();

        // Add gateway calls if gateway is configured
        if (gatewayConfig.chainId != 0) {
            Call[][] memory gwCalls = new Call[][](6);
            gwCalls[0] = allCalls[0];
            gwCalls[1] = allCalls[1];
            gwCalls[2] = allCalls[2];
            gwCalls[3] = allCalls[3];
            gwCalls[4] = prepareNewChainCreationParamsCallForGateway(
                newConfig.priorityTxsL2GasLimit,
                newConfig.maxExpectedL1GasPrice
            );
            gwCalls[5] = provideSetNewVersionUpgradeCallForGateway(
                newConfig.priorityTxsL2GasLimit,
                newConfig.maxExpectedL1GasPrice
            );

            calls = mergeCallsArray(gwCalls);
        } else {
            calls = mergeCallsArray(allCalls);
        }
    }

    /// @notice Override prepareCreateNewChainCall to use chain creation params with new verifier
    function prepareCreateNewChainCall(uint256 chainId) public view virtual override returns (Call[] memory result) {
        require(addresses.bridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        ChainCreationParams memory chainCreationParams = _getChainCreationParamsWithNewVerifier(addresses.stateTransition);

        bytes32 newChainAssetId = Bridgehub(addresses.bridgehub.bridgehubProxy).baseTokenAssetId(gatewayConfig.chainId);
        result = new Call[](1);
        result[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(
                IBridgehub.createNewChain,
                (
                    chainId,
                    addresses.stateTransition.chainTypeManagerProxy,
                    newChainAssetId,
                    5,
                    msg.sender,
                    abi.encode(
                        abi.encode(chainCreationParams.diamondCut),
                        chainCreationParams.forceDeploymentsData
                    ),
                    new bytes[](0)
                )
            )
        });
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();

        prepareDefaultTestUpgradeCalls();
    }

    /// @notice Full default upgrade preparation flow - simplified for verifier only
    function prepareEcosystemUpgrade() public virtual override {
        deployNewEcosystemContractsL1();
        console.log("Verifier contracts deployed on L1!");
        deployNewEcosystemContractsGW();
        console.log("Verifier contracts deployed on GW!");
        publishBytecodes();
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }
}
