// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Test} from "forge-std/Test.sol";

import {EcosystemUpgrade} from "deploy-scripts/upgrade/EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

// For now, this test is testing "stage" - as mainnet wasn't updated yet.
string constant ECOSYSTEM_INPUT = "/upgrade-envs/v0.27.0-evm/stage.toml";
string constant ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage.toml";
string constant CHAIN_INPUT = "/upgrade-envs/v0.27.0-evm/stage-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage-era.toml";

contract UpgradeIntegrationTest is Test {
    EcosystemUpgrade ecosystemUpgrade;
    ChainUpgrade chainUpgrade;

    function setUp() public {
        ecosystemUpgrade = new EcosystemUpgrade();
        ecosystemUpgrade.initialize(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);

        chainUpgrade = new ChainUpgrade();
    }

    // NOTE: this test is currently testing "stage" - as mainnet is not upgraded yet.
    function test_MainnetFork() public {
        console.log("Preparing ecosystem upgrade");
        ecosystemUpgrade.prepareEcosystemUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT, CHAIN_INPUT, CHAIN_OUTPUT);

        // Note: stage1 calls are not used for V27 upgrade. This step will be required after Gateway launch
        (
            Call[] memory upgradeGovernanceStage0Calls,
            Call[] memory upgradeGovernanceStage1Calls,
            Call[] memory upgradeGovernanceStage2Calls
        ) = ecosystemUpgrade.prepareDefaultGovernanceCalls();

        // console.log("Starting ecosystem upgrade stage 0!");
        // governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage0Calls);

        console.log("Starting ecosystem upgrade stage 1!");
        _governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage1Calls);

        // console.log("Starting ecosystem upgrade stage 2!");

        // Not needed without stage 1
        // if (ecosystemUpgrade.getGovernanceUpgradeInitialDelay() != 0) {
        //     vm.warp(block.timestamp + ecosystemUpgrade.getGovernanceUpgradeInitialDelay());
        // }

        // governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        // Now, the admin of the Era needs to call the upgrade function.
        // TODO: We do not include calls that ensure that the server is ready for the sake of brevity.
        chainUpgrade.upgradeChain(
            ecosystemUpgrade.getOldProtocolVersion(),
            ecosystemUpgrade.generateUpgradeCutData(ecosystemUpgrade.getAddresses().stateTransition)
        );

        // TODO: here we should include tests that depoists work for upgraded chains
        // including era specific deposit/withdraw functions
        // We also may need to test that normal flow of block commit / verify / execute works (but it is hard)
        // so it was tested in e2e local environment.
    }

    function _upgradeChain(uint256 oldProtocolVersion, Diamond.DiamondCutData memory chainUpgradeInfo) internal virtual {}

    /// @dev Executes a series of governance calls.
    function _governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        vm.startBroadcast(governanceAddr);
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];
            (bool success, ) = payable(call.target).call{value: call.value}(call.data);
            require(success, "Multicall failed");
        }
        vm.stopBroadcast();
    }

    function _forceMoveOwnership(address _contract, address _to, bool _twoStep) internal {
        address owner = Ownable2StepUpgradeable(_contract).owner();
        if (owner == _to) {
            // It is already an owner, there is nothing to do.
            return;
        }

        vm.broadcast(owner);
        Ownable2StepUpgradeable(_contract).transferOwnership(_to);

        if (_twoStep) {
            vm.broadcast(_to);
            Ownable2StepUpgradeable(_contract).acceptOwnership();
        }
    }

    function _prepareEcosystemOwner() internal {
        // This data is generated before the protocol upgrade handler has received the ownership for the contracts.
        // Thus, we manually set it as its owner.
        // address newProtocolUpgradeHandler = generateUpgradeData.getProtocolUpgradeHandlerAddress();

        // _forceMoveOwnership(generateUpgradeData.getTransparentProxyAdmin(), newProtocolUpgradeHandler, false);
        // _forceMoveOwnership(generateUpgradeData.getBridgehub(), newProtocolUpgradeHandler, true);
        // _forceMoveOwnership(generateUpgradeData.getChainTypeManager(), newProtocolUpgradeHandler, true);
        // _forceMoveOwnership(generateUpgradeData.getL1LegacySharedBridge(), newProtocolUpgradeHandler, true);
    }

    function _mainnetForkTestImpl() internal {
        console.log("Preparing ecosystem contracts");
        // _prepareEcosystemContracts();

        console.log("Preparing chain for the upgrade");
        // _prepareChain();

        console.log("Setting up ownership");
        _prepareEcosystemOwner();

        console.log("Starting stage1 of the upgrade!");
        // Call[] memory stage1Calls = _getStage1UpgradeCalls();
        // _governanceMulticall(_getProtocolUpgradeHandlerAddress(), stage1Calls);

        // console.log("Stage1 is done, now all the chains have to upgrade to the new version");
        // console.log("Upgrading Era");

        // // Upgrade the chain. Note: the chainUpgrade also updates other contracts as required.
        // _upgradeChain(_getOldProtocolVersion(), _getChainUpgradeInfo());

        // // Try to create a new chain using the legacy interface (which is expected to revert).
        // _createNewChain(101101, true);

        // vm.warp(block.timestamp + _getInitialDelay());

        // console.log("Starting stage2 of the upgrade!");
        // // Execute stage2 calls.
        // _governanceMulticall(_getProtocolUpgradeHandlerAddress(), _getStage2UpgradeCalls());

        // // After stage2, deploying a new chain should work.
        // _createNewChain(101101, false);
    }
}

/**
 * @title UpgradeTestScriptBased
 * @dev This implementation of UpgradeTestAbstract generates the upgrade data
 * locally by instantiating EcosystemUpgrade and ChainUpgrade.
 */
// contract UpgradeTestScriptBased is UpgradeTestAbstract {
//     function setUp() public {
//         _setUp();
//     }

//     // --- Implementation of virtual functions that forward to generateUpgradeData ---

//     function _getEcosystemAdmin() internal view override returns (address) {
//         return generateUpgradeData.getEcosystemAdmin();
//     }

//     function _getBridgehub() internal view override returns (address) {
//         return generateUpgradeData.getBridgehub();
//     }

//     function _getChainTypeManager() internal view override returns (address) {
//         return generateUpgradeData.getChainTypeManager();
//     }

//     function _getDummyDiamondCutData() internal view override returns (Diamond.DiamondCutData memory) {
//         return generateUpgradeData.getDummyDiamondCutData();
//     }

//     function _getDiamondCutData() internal view override returns (bytes memory) {
//         return generateUpgradeData.getDiamondCutData();
//     }

//     function _prepareForceDeploymentsData() internal view override returns (bytes memory) {
//         return generateUpgradeData.prepareForceDeploymentsData();
//     }

//     function _getStage1UpgradeCalls() internal override returns (Call[] memory) {
//         return generateUpgradeData.getStage1UpgradeCalls();
//     }

//     function _getProtocolUpgradeHandlerAddress() internal view override returns (address) {
//         return generateUpgradeData.getProtocolUpgradeHandlerAddress();
//     }

//     function _getOldProtocolVersion() internal view override returns (uint256) {
//         return generateUpgradeData.getOldProtocolVersion();
//     }

//     function _getChainUpgradeInfo() internal override returns (Diamond.DiamondCutData memory) {
//         return generateUpgradeData.getChainUpgradeInfo();
//     }

//     function _getInitialDelay() internal view override returns (uint256) {
//         return generateUpgradeData.getInitialDelay();
//     }

//     // --- Implementation of virtual functions for preparing upgrades --------

//     function _prepareEcosystemContracts() internal override {
//         generateUpgradeData.prepareEcosystemContracts(vm.envString("ECOSYSTEM_INPUT"), ECOSYSTEM_OUTPUT);
//     }

//     function _prepareChain() internal override {
//         chainUpgrade.prepareChain(
//             vm.envString("ECOSYSTEM_INPUT"),
//             ECOSYSTEM_OUTPUT,
//             vm.envString("CHAIN_INPUT"),
//             CHAIN_OUTPUT
//         );
//     }

//     function _upgradeChain(
//         uint256 oldProtocolVersion,
//         Diamond.DiamondCutData memory chainUpgradeInfo
//     ) internal override {
//         chainUpgrade.upgradeChain(oldProtocolVersion, chainUpgradeInfo);
//     }

//     function _getStage2UpgradeCalls() internal override returns (Call[] memory) {
//         return generateUpgradeData.getStage2UpgradeCalls();
//     }

//     function test_MainnetForkScriptBased() public {
//         _mainnetForkTestImpl();
//     }
// }

// /**
//  * @title UpgradeTestFileBased
//  * @dev This implementation of UpgradeTestAbstract reads the upgrade data from a file
//  */
// contract UpgradeTestFileBased is UpgradeTestAbstract {
//     using stdToml for string;

//     string internal outputFile;
//     function setUp() public {
//         _setUp();
//         string memory root = vm.projectRoot();
//         outputFile = string.concat(root, vm.envString("UPGRADE_OUTPUT"));
//     }

//     // --- Implementation of virtual functions that forward to generateUpgradeData ---

//     function _getEcosystemAdmin() internal view override returns (address) {
//         return generateUpgradeData.getEcosystemAdmin();
//     }

//     function _getBridgehub() internal view override returns (address) {
//         return generateUpgradeData.getBridgehub();
//     }

//     function _getChainTypeManager() internal view override returns (address) {
//         return generateUpgradeData.getChainTypeManager();
//     }

//     function _getDummyDiamondCutData() internal view override returns (Diamond.DiamondCutData memory) {
//         return generateUpgradeData.getDummyDiamondCutData();
//     }

//     function _getDiamondCutData() internal view override returns (bytes memory) {
//         string memory toml = vm.readFile(outputFile);
//         return toml.readBytes("$.contracts_config.diamond_cut_data");
//     }

//     function _prepareForceDeploymentsData() internal view override returns (bytes memory) {
//         string memory toml = vm.readFile(outputFile);
//         return toml.readBytes("$.contracts_config.force_deployments_data");
//     }

//     function _getStage1UpgradeCalls() internal override returns (Call[] memory) {
//         string memory toml = vm.readFile(outputFile);
//         return abi.decode(toml.readBytes("$.governance_stage1_calls"), (Call[]));
//     }

//     function _getProtocolUpgradeHandlerAddress() internal view override returns (address) {
//         return generateUpgradeData.getProtocolUpgradeHandlerAddress();
//     }

//     function _getOldProtocolVersion() internal view override returns (uint256) {
//         return generateUpgradeData.getOldProtocolVersion();
//     }

//     function _getChainUpgradeInfo() internal override returns (Diamond.DiamondCutData memory) {
//         string memory toml = vm.readFile(outputFile);
//         return abi.decode(toml.readBytes("$.chain_upgrade_diamond_cut"), (Diamond.DiamondCutData));
//     }

//     function _getInitialDelay() internal view override returns (uint256) {
//         return generateUpgradeData.getInitialDelay();
//     }

//     // --- Implementation of virtual functions for preparing upgrades --------

//     function _prepareEcosystemContracts() internal override {
//         generateUpgradeData.testInitialize(vm.envString("ECOSYSTEM_INPUT"), ECOSYSTEM_OUTPUT);
//     }

//     function _prepareChain() internal override {
//         chainUpgrade.prepareChain(
//             vm.envString("ECOSYSTEM_INPUT"),
//             ECOSYSTEM_OUTPUT,
//             vm.envString("CHAIN_INPUT"),
//             CHAIN_OUTPUT
//         );
//     }

//     function _upgradeChain(
//         uint256 oldProtocolVersion,
//         Diamond.DiamondCutData memory chainUpgradeInfo
//     ) internal override {
//         chainUpgrade.upgradeChain(oldProtocolVersion, chainUpgradeInfo);
//     }

//     function _getStage2UpgradeCalls() internal override returns (Call[] memory) {
//         string memory toml = vm.readFile(outputFile);
//         return abi.decode(toml.readBytes("$.governance_stage2_calls"), (Call[]));
//     }

//     function test_MainnetForkFileBased() public {
//         _mainnetForkTestImpl();

//         // We should also double check that at least emergency upgrades work.
//         address puh = generateUpgradeData.getProtocolUpgradeHandlerAddress();
//         address emergencyUpgradeBoard = IProtocolUpgradeHandler(puh).emergencyUpgradeBoard();

//         IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](1);
//         vm.startBroadcast(emergencyUpgradeBoard);
//         IProtocolUpgradeHandler(puh).executeEmergencyUpgrade(
//             IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: emergencyUpgradeBoard, salt: bytes32(0)})
//         );
//         vm.stopBroadcast();
//     }
// }
