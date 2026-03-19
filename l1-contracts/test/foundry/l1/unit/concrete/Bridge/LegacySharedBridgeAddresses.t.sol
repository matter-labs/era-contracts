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

    address constant STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = LegacySharedBridgeAddresses
        .STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS;
    address constant TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = LegacySharedBridgeAddresses
        .TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS;
    address constant MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = LegacySharedBridgeAddresses
        .MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS;

    function setUp() public {
        wrapper = new LegacySharedBridgeAddressesWrapper();
    }

    function test_getLegacySharedBridgeAddressOnGateway_stageEcosystem() public view {
        SharedBridgeOnChainId[] memory result = wrapper.getLegacySharedBridgeAddressOnGateway(
            STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS
        );
        assertEq(result.length, LegacySharedBridgeAddresses.STAGE_LEGACY_BRIDGES);
    }

    function test_getLegacySharedBridgeAddressOnGateway_testnetEcosystem() public view {
        SharedBridgeOnChainId[] memory result = wrapper.getLegacySharedBridgeAddressOnGateway(
            TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS
        );
        assertEq(result.length, LegacySharedBridgeAddresses.TESTNET_LEGACY_BRIDGES);
    }

    function test_getLegacySharedBridgeAddressOnGateway_mainnetEcosystem() public view {
        SharedBridgeOnChainId[] memory result = wrapper.getLegacySharedBridgeAddressOnGateway(
            MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS
        );
        assertEq(result.length, LegacySharedBridgeAddresses.MAINNET_LEGACY_BRIDGES);
    }

    function test_getLegacySharedBridgeAddressOnGateway_invalidAddress() public {
        address invalidAddress = makeAddr("invalid");

        vm.expectRevert(abi.encodeWithSelector(InvalidL1AssetRouter.selector, invalidAddress));
        wrapper.getLegacySharedBridgeAddressOnGateway(invalidAddress);
    }

    function testFuzz_getLegacySharedBridgeAddressOnGateway_revertsForUnknownAddress(address randomAddress) public {
        vm.assume(randomAddress != STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS);
        vm.assume(randomAddress != TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS);
        vm.assume(randomAddress != MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS);

        vm.expectRevert(abi.encodeWithSelector(InvalidL1AssetRouter.selector, randomAddress));
        wrapper.getLegacySharedBridgeAddressOnGateway(randomAddress);
    }
}
