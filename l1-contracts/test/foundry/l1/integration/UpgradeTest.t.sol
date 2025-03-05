// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Test} from "forge-std/Test.sol";

import {EcosystemUpgrade_v26_1} from "deploy-scripts/upgrade/EcosystemUpgrade_v26_1.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

string constant ECOSYSTEM_INPUT = "/upgrade-envs/v0.26.1-gateway-patch/stage-proofs.toml";
string constant ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage-proofs.toml";
string constant CHAIN_INPUT = "/upgrade-envs/v0.26.1-gateway-patch/stage-proofs-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage-proofs-era.toml";

/// @dev This interface is used to call the legacy Bridgehub createNewChain
interface BridgehubLegacy {
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        uint256 _salt,
        address _admin,
        bytes calldata _initData
    ) external;
}

/**
 * @title UpgradeTestAbstract
 * @dev This abstract contract defines internal virtual methods that must be implemented
 * to provide the necessary upgrade data. This allows one implementation to generate data locally,
 * and another to read it from file.
 */
abstract contract UpgradeTestAbstract is Test {
    EcosystemUpgrade_v26_1 internal generateUpgradeData;
    ChainUpgrade internal chainUpgrade;

    function _setUp() internal {
        generateUpgradeData = new EcosystemUpgrade_v26_1();
        chainUpgrade = new ChainUpgrade();
    }

    // --- Virtual functions for EcosystemUpgrade_v26_1 data -----------------------

    function _getEcosystemAdmin() internal view virtual returns (address);
    function _getBridgehub() internal view virtual returns (address);
    function _getChainTypeManager() internal view virtual returns (address);
    function _getDiamondCutData() internal view virtual returns (bytes memory);
    function _prepareForceDeploymentsData() internal view virtual returns (bytes memory);
    function _getUpgradeCalls() internal virtual returns (Call[] memory);
    function _getProtocolUpgradeHandlerAddress() internal view virtual returns (address);
    function _getOldProtocolVersion() internal view virtual returns (uint256);

    // --- Virtual functions for chain upgrade management -----------------------

    function _prepareEcosystemContracts() internal virtual;

    function _prepareChain() internal virtual;

    function _upgradeChain(uint256 oldProtocolVersion, Diamond.DiamondCutData memory chainUpgradeInfo) internal virtual;

    // --- Shared internal helper functions -------------------------------------

    /// @dev Creates a new chain. In the legacy case, we expect a revert.
    function _createNewChain(uint256 chainId) internal {
        address ecosystemAdmin = _getEcosystemAdmin();
        // When using the new interface, we need to provide an asset id.
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        address ctm = _getChainTypeManager();

        Bridgehub bh = Bridgehub(_getBridgehub());
        vm.startBroadcast(ecosystemAdmin);
        bh.createNewChain(
            chainId,
            ctm,
            ethAssetId,
            uint256(keccak256(abi.encodePacked(chainId))),
            ecosystemAdmin,
            abi.encode(_getDiamondCutData(), _prepareForceDeploymentsData()),
            new bytes[](0)
        );
        vm.stopBroadcast();
    }

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
        address newProtocolUpgradeHandler = generateUpgradeData.getProtocolUpgradeHandlerAddress();

        _forceMoveOwnership(generateUpgradeData.getTransparentProxyAdmin(), newProtocolUpgradeHandler, false);
        _forceMoveOwnership(generateUpgradeData.getBridgehub(), newProtocolUpgradeHandler, true);
        _forceMoveOwnership(generateUpgradeData.getChainTypeManager(), newProtocolUpgradeHandler, true);
    }

    function _mainnetForkTestImpl() internal {
        console.log("Preparing ecosystem contracts");
        _prepareEcosystemContracts();

        console.log("Preparing chain for the upgrade");
        _prepareChain();

        console.log("Setting up ownership");
        _prepareEcosystemOwner();

        console.log("Posting the governance upgrade!");
        Call[] memory stage1Calls = _getUpgradeCalls();
        _governanceMulticall(_getProtocolUpgradeHandlerAddress(), stage1Calls);

        console.log("Stage1 is done, now all the chains have to upgrade to the new version");
        console.log("Upgrading Era");

        // Creating new chains should work
        _createNewChain(101101);
    }
}

/**
 * @title UpgradeTestScriptBased
 * @dev This implementation of UpgradeTestAbstract generates the upgrade data
 * locally by instantiating EcosystemUpgrade_v26_1 and ChainUpgrade.
 */
contract UpgradeTestScriptBased is UpgradeTestAbstract {
    function setUp() public {
        _setUp();
    }

    // --- Implementation of virtual functions that forward to generateUpgradeData ---

    function _getEcosystemAdmin() internal view override returns (address) {
        return generateUpgradeData.getEcosystemAdmin();
    }

    function _getBridgehub() internal view override returns (address) {
        return generateUpgradeData.getBridgehub();
    }

    function _getChainTypeManager() internal view override returns (address) {
        return generateUpgradeData.getChainTypeManager();
    }

    function _getDiamondCutData() internal view override returns (bytes memory) {
        return generateUpgradeData.getDiamondCutData();
    }

    function _prepareForceDeploymentsData() internal view override returns (bytes memory) {
        return generateUpgradeData.prepareForceDeploymentsData();
    }

    function _getUpgradeCalls() internal override returns (Call[] memory) {
        return generateUpgradeData.getUpgradeCalls();
    }

    function _getProtocolUpgradeHandlerAddress() internal view override returns (address) {
        return generateUpgradeData.getProtocolUpgradeHandlerAddress();
    }

    function _getOldProtocolVersion() internal view override returns (uint256) {
        return generateUpgradeData.getOldProtocolVersion();
    }

    // --- Implementation of virtual functions for preparing upgrades --------

    function _prepareEcosystemContracts() internal override {
        generateUpgradeData.prepareEcosystemContracts(vm.envString("ECOSYSTEM_INPUT"), ECOSYSTEM_OUTPUT);
    }

    function _prepareChain() internal override {
        chainUpgrade.prepareChain(
            vm.envString("ECOSYSTEM_INPUT"),
            ECOSYSTEM_OUTPUT,
            vm.envString("CHAIN_INPUT"),
            CHAIN_OUTPUT
        );
    }

    function _upgradeChain(
        uint256 oldProtocolVersion,
        Diamond.DiamondCutData memory chainUpgradeInfo
    ) internal override {
        chainUpgrade.upgradeChain(oldProtocolVersion, chainUpgradeInfo);
    }

    function test_StageProofsForkScriptBased() public {
        _mainnetForkTestImpl();
    }
}

/**
 * @title UpgradeTestFileBased
 * @dev This implementation of UpgradeTestAbstract reads the upgrade data from a file
 */
contract UpgradeTestFileBased is UpgradeTestAbstract {
    using stdToml for string;

    string internal outputFile;
    function setUp() public {
        _setUp();
        string memory root = vm.projectRoot();
        outputFile = string.concat(root, vm.envString("UPGRADE_OUTPUT"));
    }

    // --- Implementation of virtual functions that forward to generateUpgradeData ---

    function _getEcosystemAdmin() internal view override returns (address) {
        return generateUpgradeData.getEcosystemAdmin();
    }

    function _getBridgehub() internal view override returns (address) {
        return generateUpgradeData.getBridgehub();
    }

    function _getChainTypeManager() internal view override returns (address) {
        return generateUpgradeData.getChainTypeManager();
    }

    function _getDiamondCutData() internal view override returns (bytes memory) {
        string memory toml = vm.readFile(outputFile);
        return toml.readBytes("$.contracts_config.diamond_cut_data");
    }

    function _prepareForceDeploymentsData() internal view override returns (bytes memory) {
        string memory toml = vm.readFile(outputFile);
        return toml.readBytes("$.contracts_config.force_deployments_data");
    }

    function _getUpgradeCalls() internal override returns (Call[] memory) {
        string memory toml = vm.readFile(outputFile);
        return abi.decode(toml.readBytes("$.governance_upgrade_calls"), (Call[]));
    }

    function _getProtocolUpgradeHandlerAddress() internal view override returns (address) {
        return generateUpgradeData.getProtocolUpgradeHandlerAddress();
    }

    function _getOldProtocolVersion() internal view override returns (uint256) {
        return generateUpgradeData.getOldProtocolVersion();
    }

    // --- Implementation of virtual functions for preparing upgrades --------

    function _prepareEcosystemContracts() internal override {
        generateUpgradeData.testInitialize(vm.envString("ECOSYSTEM_INPUT"), ECOSYSTEM_OUTPUT);
    }

    function _prepareChain() internal override {
        chainUpgrade.prepareChain(
            vm.envString("ECOSYSTEM_INPUT"),
            ECOSYSTEM_OUTPUT,
            vm.envString("CHAIN_INPUT"),
            CHAIN_OUTPUT
        );
    }

    function _upgradeChain(
        uint256 oldProtocolVersion,
        Diamond.DiamondCutData memory chainUpgradeInfo
    ) internal override {
        chainUpgrade.upgradeChain(oldProtocolVersion, chainUpgradeInfo);
    }

    function test_StageProofsForkFileBased() public {
        _mainnetForkTestImpl();

        // We should also double check that at least emergency upgrades work.
        address puh = generateUpgradeData.getProtocolUpgradeHandlerAddress();
        address emergencyUpgradeBoard = IProtocolUpgradeHandler(puh).emergencyUpgradeBoard();

        IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](1);
        vm.startBroadcast(emergencyUpgradeBoard);
        IProtocolUpgradeHandler(puh).executeEmergencyUpgrade(
            IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: emergencyUpgradeBoard, salt: bytes32(0)})
        );
        vm.stopBroadcast();
    }
}
