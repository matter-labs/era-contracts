// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    LegacySharedBridgeAddresses,
    SharedBridgeOnChainId
} from "contracts/bridge/asset-tracker/LegacySharedBridgeAddresses.sol";
import {InvalidL1AssetRouter} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";

/// @notice Wrapper contract to expose library functions
contract LegacySharedBridgeAddressesWrapper {
    function getLegacySharedBridgeAddressOnGateway(
        address _l1AssetRouter
    ) external pure returns (SharedBridgeOnChainId[] memory) {
        return LegacySharedBridgeAddresses.getLegacySharedBridgeAddressOnGateway(_l1AssetRouter);
    }
}

/// @notice Unit tests for LegacySharedBridgeAddresses library
contract LegacySharedBridgeAddressesTest is Test {
    LegacySharedBridgeAddressesWrapper internal wrapper;

    // The constant addresses from the library
    address constant STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = address(0);
    address constant TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = address(0);
    address constant MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = address(0);

    function setUp() public {
        wrapper = new LegacySharedBridgeAddressesWrapper();
    }

    function test_getLegacySharedBridgeAddressOnGateway_stageEcosystem() public view {
        // Since all addresses are 0, first branch (stage) will match
        SharedBridgeOnChainId[] memory result = wrapper.getLegacySharedBridgeAddressOnGateway(
            STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS
        );

        // Should return empty array since STAGE_LEGACY_BRIDGES = 0
        assertEq(result.length, 0);
    }

    function test_getLegacySharedBridgeAddressOnGateway_invalidAddress() public {
        // Any non-zero address should revert since all ecosystem addresses are 0
        address invalidAddress = makeAddr("invalid");

        vm.expectRevert(abi.encodeWithSelector(InvalidL1AssetRouter.selector, invalidAddress));
        wrapper.getLegacySharedBridgeAddressOnGateway(invalidAddress);
    }

    function testFuzz_getLegacySharedBridgeAddressOnGateway_revertsForNonZeroAddress(address randomAddress) public {
        // Skip address(0) since that matches the ecosystem addresses
        vm.assume(randomAddress != address(0));

        vm.expectRevert(abi.encodeWithSelector(InvalidL1AssetRouter.selector, randomAddress));
        wrapper.getLegacySharedBridgeAddressOnGateway(randomAddress);
    }
}
