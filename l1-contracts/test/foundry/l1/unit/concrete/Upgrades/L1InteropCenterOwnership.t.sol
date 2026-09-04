// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

// The aggregate's unrelated ownables share this fixture; center ownership and
// the Governance schedule/execute flow use their real implementations.
contract OwnershipDiscoveryFixture is Ownable2Step {
    address public interopCenter;

    function setInteropCenter(address _center) external {
        interopCenter = _center;
    }
    function assetRouter() external view returns (address) {
        return address(this);
    }
    function chainAssetHandler() external view returns (address) {
        return address(this);
    }
    function l1CtmDeployer() external view returns (address) {
        return address(this);
    }
    function L1_NULLIFIER() external view returns (address) {
        return address(this);
    }
}

contract L1InteropCenterOwnershipTest is Test {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    AdminFunctions internal script;
    Governance internal governance;
    OwnershipDiscoveryFixture internal bridgehub;
    L1InteropCenter internal center;

    function setUp() public {
        vm.warp(block.timestamp + 1);
        script = new AdminFunctions();
        governance = new Governance(address(this), address(0), 0);
        bridgehub = new OwnershipDiscoveryFixture();
        L1InteropCenter implementation = new L1InteropCenter(IL1Bridgehub(address(bridgehub)));
        center = L1InteropCenter(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropCenter.initialize, (address(this)))
                )
            )
        );
        bridgehub.setInteropCenter(address(center));
    }

    function test_aggregateAcceptsCenterOwnershipAndGovernanceCanPause() public {
        center.transferOwnership(address(governance));
        vm.expectEmit(true, true, false, true, address(center));
        emit OwnershipTransferred(address(this), address(governance));
        script.governanceAcceptOwnerAggregated(address(governance), address(bridgehub));
        assertEq(center.owner(), address(governance));
        assertEq(center.pendingOwner(), address(0));
        vm.prank(address(governance));
        center.pause();
        assertTrue(center.paused());

        script.governanceAcceptOwnerAggregated(address(governance), address(bridgehub));
        assertEq(center.owner(), address(governance));
    }

    function test_aggregateLeavesOwnershipPendingToAnotherOwner() public {
        address pendingOwner = makeAddr("pendingOwner");
        center.transferOwnership(pendingOwner);
        script.governanceAcceptOwnerAggregated(address(governance), address(bridgehub));
        assertEq(center.owner(), address(this));
        assertEq(center.pendingOwner(), pendingOwner);
    }
}
