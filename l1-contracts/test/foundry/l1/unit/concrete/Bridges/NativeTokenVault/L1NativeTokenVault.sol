// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {AssetTrackerBase} from "contracts/bridge/asset-tracker/AssetTrackerBase.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AssetIdAlreadyRegistered, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract SomeToken {
    constructor() {}

    function name() external {
        // Just some function so that the bytecode is not empty,
        // the actional functionality is not used.
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract L1NativeTokenVaultTest is Test {
    address assetRouter;

    L1NativeTokenVault ntv;
    SomeToken token;
    address assetTracker;
    address owner;

    uint256 constant CHAIN_ID = 123;
    bytes32 constant ASSET_ID = keccak256("assetId");

    function setUp() public {
        assetRouter = makeAddr("assetRouter");
        owner = makeAddr("owner");

        ntv = new L1NativeTokenVault(makeAddr("wethToken"), assetRouter, IL1Nullifier(address(0)));
        assetTracker = makeAddr("assetTracker");
        vm.prank(address(0));
        ntv.setAssetTracker(assetTracker);

        token = new SomeToken();
    }

    function test_revertWhenRegisteringSameAddressTwice() external {
        vm.mockCall(
            assetRouter,
            abi.encodeCall(
                L1AssetRouter.setAssetHandlerAddressThisChain,
                (bytes32(uint256(uint160(address(token)))), address(ntv))
            ),
            hex""
        );
        bytes[] memory zeros = new bytes[](2);
        zeros[0] = abi.encode(0);
        zeros[1] = abi.encode(0);
        vm.mockCalls(assetTracker, abi.encodeWithSelector(AssetTrackerBase.registerNewToken.selector), zeros);
        ntv.registerToken(address(token));

        vm.expectRevert(AssetIdAlreadyRegistered.selector);
        ntv.registerToken(address(token));
    }

    function test_chainBalance_ReturnsDeprecatedBalance() external view {
        // chainBalance should return 0 for uninitialized values
        uint256 balance = ntv.chainBalance(CHAIN_ID, ASSET_ID);
        assertEq(balance, 0);
    }

    function test_MigrateTokenBalanceToAssetTracker_OnlyAssetTracker() external {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        ntv.migrateTokenBalanceToAssetTracker(CHAIN_ID, ASSET_ID);
    }

    function test_MigrateTokenBalanceToAssetTracker_Success() external {
        // Call as assetTracker should succeed
        vm.prank(assetTracker);
        uint256 amount = ntv.migrateTokenBalanceToAssetTracker(CHAIN_ID, ASSET_ID);
        // Should return 0 since DEPRECATED_chainBalance is not set
        assertEq(amount, 0);
    }

    function test_SetAssetTracker_OnlyOwner() external {
        address newAssetTracker = makeAddr("newAssetTracker");

        // Non-owner should fail
        vm.prank(makeAddr("randomUser"));
        vm.expectRevert("Ownable: caller is not the owner");
        ntv.setAssetTracker(newAssetTracker);
    }

    function test_SetAssetTracker_Success() external {
        address newAssetTracker = makeAddr("newAssetTracker");

        // Owner (address(0) in this test setup) should succeed
        vm.prank(address(0));
        ntv.setAssetTracker(newAssetTracker);

        // Verify by checking the new assetTracker can call onlyAssetTracker functions
        vm.prank(newAssetTracker);
        ntv.migrateTokenBalanceToAssetTracker(CHAIN_ID, ASSET_ID);
    }

    function test_RegisterEthToken() external {
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

        vm.mockCall(
            assetRouter,
            abi.encodeCall(
                L1AssetRouter.setAssetHandlerAddressThisChain,
                (ethAssetId, address(ntv))
            ),
            hex""
        );
        bytes[] memory zeros = new bytes[](2);
        zeros[0] = abi.encode(0);
        zeros[1] = abi.encode(0);
        vm.mockCalls(assetTracker, abi.encodeWithSelector(AssetTrackerBase.registerNewToken.selector), zeros);

        ntv.registerEthToken();
    }

    function test_L1_CHAIN_ID() external view {
        assertEq(ntv.L1_CHAIN_ID(), block.chainid);
    }

    function test_BASE_TOKEN_ASSET_ID() external view {
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        assertEq(ntv.BASE_TOKEN_ASSET_ID(), expectedAssetId);
    }

    function test_WETH_TOKEN() external {
        assertEq(address(ntv.WETH_TOKEN()), makeAddr("wethToken"));
    }

    function test_ASSET_ROUTER() external {
        assertEq(address(ntv.ASSET_ROUTER()), assetRouter);
    }
}
