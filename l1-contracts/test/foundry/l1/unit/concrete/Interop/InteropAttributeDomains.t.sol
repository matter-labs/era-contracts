// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteropAttributeParser} from "contracts/interop/InteropAttributeParser.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {ZeroAddress, SlotOccupied} from "contracts/common/L1ContractErrors.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract InteropAttributeDomainsTest is Test {
    L1InteropCenter internal center;
    InteropAttributeParser internal parser;

    function setUp() public {
        center = new L1InteropCenter(IL1Bridgehub(makeAddr("bridgehub")));
        parser = new InteropAttributeParser();
    }

    function test_l2RejectsL1Attributes() public {
        bytes[] memory attributes = new bytes[](1);
        bytes4[2] memory selectors = [
            IERC7786Attributes.l1ToL2TransactionParams.selector,
            IERC7786Attributes.factoryDeps.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            attributes[0] = abi.encodePacked(selectors[i]);
            assertFalse(parser.supportsAttribute(selectors[i]));
            vm.expectRevert(abi.encodeWithSelector(IERC7786GatewaySource.UnsupportedAttribute.selector, selectors[i]));
            parser.parseAttributes(attributes, IInteropCenter.AttributeParsingRestrictions.CallAndBundleAttributes);
        }
    }

    function test_l1RejectsL2Attributes() public {
        bytes4[5] memory selectors = [
            IERC7786Attributes.executionAddress.selector,
            IERC7786Attributes.unbundlerAddress.selector,
            IERC7786Attributes.useFixedFee.selector,
            IERC7786Attributes.atomicBundle.selector,
            IERC7786Attributes.interopBundleSalt.selector
        ];
        bytes[] memory attributes = new bytes[](1);
        for (uint256 i = 0; i < selectors.length; ++i) {
            attributes[0] = abi.encodePacked(selectors[i]);
            assertFalse(center.supportsAttribute(selectors[i]));
            vm.expectRevert(abi.encodeWithSelector(IERC7786GatewaySource.UnsupportedAttribute.selector, selectors[i]));
            center.parseL1Attributes(attributes);
        }
    }

    function test_initializeLocksImplementationAndProxy() public {
        vm.expectRevert(SlotOccupied.selector);
        center.initialize(address(this));
        address owner = makeAddr("owner");
        L1InteropCenter proxy = L1InteropCenter(
            address(
                new TransparentUpgradeableProxy(
                    address(center),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropCenter.initialize, (owner))
                )
            )
        );
        assertEq(proxy.owner(), owner);
        assertFalse(proxy.paused());
        vm.expectRevert(SlotOccupied.selector);
        proxy.initialize(address(this));
        vm.expectRevert("Ownable: caller is not the owner");
        proxy.pause();
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);
        proxy.pause();
        assertTrue(proxy.paused());
        vm.expectRevert("Ownable: caller is not the owner");
        proxy.unpause();
        vm.prank(owner);
        proxy.unpause();
        assertFalse(proxy.paused());
    }

    function test_initializeRejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new L1InteropCenter(IL1Bridgehub(address(0)));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(center),
            makeAddr("proxyAdmin"),
            abi.encodeCall(L1InteropCenter.initialize, (address(0)))
        );
    }

    event Paused(address account);
}
