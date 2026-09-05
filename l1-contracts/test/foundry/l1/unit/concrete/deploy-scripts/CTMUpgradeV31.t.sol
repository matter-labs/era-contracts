// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgrade_v31} from "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IServerNotifier} from "contracts/governance/IServerNotifier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IUpgradePreconditionChecker} from "contracts/upgrades/IUpgradePreconditionChecker.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {PriorityOpLowerBound} from "contracts/upgrades/PriorityOpLowerBound.sol";
import {V32UpgradePreconditionChecker} from "contracts/upgrades/V32UpgradePreconditionChecker.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @notice Isolates v31 call generation from the full deployment flow.
contract CTMUpgradeV31Harness is CTMUpgrade_v31 {
    function configure(
        address _serverNotifier,
        address _chainTypeManager,
        address _upgradeStageValidator,
        address _upgradePreconditionChecker,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external {
        ctmAddresses.stateTransition.proxies.serverNotifier = _serverNotifier;
        ctmAddresses.stateTransition.proxies.chainTypeManager = _chainTypeManager;
        upgradeAddresses.upgradeStageValidator = _upgradeStageValidator;
        upgradePreconditionChecker = _upgradePreconditionChecker;
        newConfig.oldProtocolVersion = _oldProtocolVersion;
        config.contracts.chainCreationParams.latestProtocolVersion = _newProtocolVersion;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);
        newlyGeneratedData.upgradeCutData = abi.encode(
            Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: new bytes(0)})
        );
    }
}

contract CTMUpgradeV31Test is Test {
    CTMUpgradeV31Harness internal harness;
    ProxyAdmin internal proxyAdmin;
    ServerNotifier internal serverNotifier;
    address internal operationalAdmin;
    address internal chainTypeManager;
    address internal upgradeStageValidator;
    address internal upgradePreconditionChecker;
    uint256 internal oldProtocolVersion;
    uint256 internal newProtocolVersion;

    function setUp() public {
        harness = new CTMUpgradeV31Harness();
        operationalAdmin = makeAddr("operational admin");
        chainTypeManager = makeAddr("chain type manager");
        upgradeStageValidator = makeAddr("upgrade stage validator");
        upgradePreconditionChecker = address(new V32UpgradePreconditionChecker(new PriorityOpLowerBound()));
        oldProtocolVersion = uint256(keccak256("old protocol version"));
        newProtocolVersion = uint256(keccak256("new protocol version"));

        proxyAdmin = new ProxyAdmin();
        ServerNotifier implementation = new ServerNotifier();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeCall(ServerNotifier.initialize, (address(this)))
        );
        serverNotifier = ServerNotifier(address(proxy));

        proxyAdmin.transferOwnership(operationalAdmin);
        serverNotifier.transferOwnership(operationalAdmin);
        harness.configure(
            address(serverNotifier),
            chainTypeManager,
            upgradeStageValidator,
            upgradePreconditionChecker,
            oldProtocolVersion,
            newProtocolVersion
        );
    }

    function test_prepareVersionSpecificCTMAdminCalls_acceptsExpectedPendingOwnerBeforeRegistration() public {
        Call[] memory calls = harness.prepareVersionSpecificCTMAdminCalls();
        _executeRegistrationCalls(calls);
    }

    function test_prepareVersionSpecificCTMAdminCalls_skipsAcceptanceWhenAlreadyOwned() public {
        vm.prank(operationalAdmin);
        serverNotifier.acceptOwnership();

        Call[] memory calls = harness.prepareVersionSpecificCTMAdminCalls();
        _executeRegistrationCalls(calls);
    }

    function _executeRegistrationCalls(Call[] memory _calls) private {
        vm.startPrank(operationalAdmin);
        for (uint256 i = 0; i < _calls.length; i++) {
            if (i == _calls.length - 1) {
                vm.expectEmit(true, false, false, true, address(serverNotifier));
                emit IServerNotifier.UpgradePreconditionCheckerSet(oldProtocolVersion, upgradePreconditionChecker);
            }
            (bool success, ) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            assertTrue(success, "generated CTM-admin call failed");
        }
        vm.stopPrank();
        assertEq(serverNotifier.owner(), operationalAdmin);
        assertEq(serverNotifier.pendingOwner(), address(0));
        assertEq(address(serverNotifier.upgradePreconditionChecker(oldProtocolVersion)), upgradePreconditionChecker);
    }

    function test_prepareVersionSpecificCTMAdminCalls_revertsForUnexpectedPendingOwner() public {
        serverNotifier.transferOwnership(makeAddr("unexpected pending owner"));

        vm.expectRevert(bytes("v31: ServerNotifier pending owner is not the operational admin"));
        harness.prepareVersionSpecificCTMAdminCalls();
    }

    function test_prepareVersionSpecificCTMAdminCalls_revertsForStalePendingOwner() public {
        vm.startPrank(operationalAdmin);
        serverNotifier.acceptOwnership();
        serverNotifier.transferOwnership(makeAddr("stale pending owner"));
        vm.stopPrank();

        vm.expectRevert(bytes("v31: ServerNotifier has a stale pending owner"));
        harness.prepareVersionSpecificCTMAdminCalls();
    }

    function test_provideSetNewVersionUpgradeCall_placesCheckerGateImmediatelyBeforePublication() public {
        Call[] memory calls = harness.provideSetNewVersionUpgradeCall();

        assertEq(calls.length, 2);
        assertEq(calls[0].target, upgradeStageValidator);
        assertEq(
            calls[0].data,
            abi.encodeCall(
                UpgradeStageValidator.checkUpgradePreconditionChecker,
                (oldProtocolVersion, IUpgradePreconditionChecker(upgradePreconditionChecker))
            )
        );
        assertEq(calls[1].target, chainTypeManager);
        assertEq(bytes4(calls[1].data), IChainTypeManager.setNewVersionUpgrade.selector);
    }
}
