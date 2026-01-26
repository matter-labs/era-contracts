// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {ExecuteMessageFailed} from "contracts/common/L1ContractErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

/// @title L2AssetRouterReceiveMessageValueForwardingRegressionTestAbstract
/// @notice Regression tests for the receiveMessage value forwarding fix in L2AssetRouter
abstract contract L2AssetRouterReceiveMessageValueForwardingRegressionTestAbstract is Test, SharedL2ContractDeployer {
    // Custom asset handler that tracks received msg.value
    MockValueTrackingAssetHandler internal mockAssetHandler;

    // Test asset ID for the mock handler
    bytes32 internal testAssetId;

    // Source chain for interop messages (must be different from L1 and current chain)
    uint256 internal sourceChainId;

    function setUp() public virtual override {
        super.setUp();

        // Deploy a mock asset handler that tracks msg.value
        mockAssetHandler = new MockValueTrackingAssetHandler();

        // Create a test asset ID
        testAssetId = keccak256(abi.encodePacked("test-asset-for-value-forwarding"));

        // Source chain must be different from L1_CHAIN_ID and current chain for interop flow
        sourceChainId = block.chainid + 100;

        // Register the mock asset handler for our test asset ID
        // We need to do this via the aliased L1 asset router (simulating a cross-chain setup message)
        vm.prank(aliasedL1AssetRouter);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).setAssetHandlerAddress(
            L1_CHAIN_ID,
            testAssetId,
            address(mockAssetHandler)
        );
    }

    function test_regression_receiveMessageForwardsValueToBridgeMint() public {
        uint256 valueToSend = 1 ether;

        // Prepare a valid finalizeDeposit payload
        bytes memory transferData = abi.encode(
            address(this), // sender
            address(this), // receiver
            address(0), // token (not used by mock)
            uint256(1000), // amount
            bytes("") // extra data
        );

        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            sourceChainId, // originChainId (different from L1 and current chain for interop)
            testAssetId,
            transferData
        );

        // Create sender bytes (ERC-7930 format) - L2AssetRouter on another L2 chain
        bytes memory sender = InteroperableAddress.formatEvmV1(sourceChainId, L2_ASSET_ROUTER_ADDR);

        // Fund the InteropHandler so it can send value
        vm.deal(L2_INTEROP_HANDLER_ADDR, valueToSend);

        // Reset the mock handler's recorded value
        mockAssetHandler.resetRecordedValue();

        // InteropHandler calls receiveMessage with value
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage{value: valueToSend}(
            bytes32(0), // receiveId
            sender,
            payload
        );

        // Verify that bridgeMint received the correct msg.value
        assertEq(mockAssetHandler.lastReceivedValue(), valueToSend, "bridgeMint should receive the full msg.value");

        // Verify the asset router doesn't have stranded ETH
        assertEq(L2_ASSET_ROUTER_ADDR.balance, 0, "Asset router should not have stranded ETH after forwarding");
    }

    /// @notice Test that zero value calls still work correctly
    /// @dev Ensures the fix doesn't break the zero-value case
    function test_regression_receiveMessageWorksWithZeroValue() public {
        // Prepare a valid finalizeDeposit payload
        bytes memory transferData = abi.encode(address(this), address(this), address(0), uint256(1000), bytes(""));

        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            sourceChainId,
            testAssetId,
            transferData
        );

        bytes memory sender = InteroperableAddress.formatEvmV1(sourceChainId, L2_ASSET_ROUTER_ADDR);

        mockAssetHandler.resetRecordedValue();

        // InteropHandler calls receiveMessage without value
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage(bytes32(0), sender, payload);

        // Verify bridgeMint received zero value
        assertEq(mockAssetHandler.lastReceivedValue(), 0, "bridgeMint should receive zero when no value is sent");
    }

    /// @notice Test that various ETH amounts are correctly forwarded
    /// @dev Fuzz test to ensure the fix works for any amount
    function testFuzz_regression_receiveMessageForwardsAnyValue(uint256 valueToSend) public {
        // Bound the value to reasonable range (avoid overflow issues)
        valueToSend = bound(valueToSend, 0, 100 ether);

        bytes memory transferData = abi.encode(address(this), address(this), address(0), uint256(1000), bytes(""));

        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            sourceChainId,
            testAssetId,
            transferData
        );

        bytes memory sender = InteroperableAddress.formatEvmV1(sourceChainId, L2_ASSET_ROUTER_ADDR);

        vm.deal(L2_INTEROP_HANDLER_ADDR, valueToSend);
        mockAssetHandler.resetRecordedValue();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage{value: valueToSend}(bytes32(0), sender, payload);

        assertEq(mockAssetHandler.lastReceivedValue(), valueToSend, "bridgeMint should receive the exact value sent");
    }

    /// @notice Test that value is forwarded even when the asset handler doesn't use it
    /// @dev The value should still be forwarded to maintain correct semantics
    function test_regression_valueForwardedEvenIfHandlerIgnoresIt() public {
        uint256 valueToSend = 0.5 ether;

        bytes memory transferData = abi.encode(address(this), address(this), address(0), uint256(500), bytes(""));

        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            sourceChainId,
            testAssetId,
            transferData
        );

        bytes memory sender = InteroperableAddress.formatEvmV1(sourceChainId, L2_ASSET_ROUTER_ADDR);

        vm.deal(L2_INTEROP_HANDLER_ADDR, valueToSend);
        mockAssetHandler.resetRecordedValue();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage{value: valueToSend}(bytes32(0), sender, payload);

        // The mock handler received the value
        assertEq(mockAssetHandler.lastReceivedValue(), valueToSend);

        // Since our mock handler accepts the ETH, verify it has the balance
        assertEq(address(mockAssetHandler).balance, valueToSend);
    }
}

/// @notice Mock asset handler that tracks the msg.value received in bridgeMint
/// @dev Used to verify that value is correctly forwarded through the call chain
contract MockValueTrackingAssetHandler is IAssetHandler {
    uint256 private _lastReceivedValue;
    bool private _valueRecorded;

    function lastReceivedValue() external view returns (uint256) {
        return _lastReceivedValue;
    }

    function resetRecordedValue() external {
        _lastReceivedValue = 0;
        _valueRecorded = false;
    }

    /// @notice Records the msg.value received during bridgeMint
    function bridgeMint(
        uint256 /* _chainId */,
        bytes32 /* _assetId */,
        bytes calldata /* _data */
    ) external payable override {
        _lastReceivedValue = msg.value;
        _valueRecorded = true;
    }

    /// @notice Not used in this test, but required by interface
    function bridgeBurn(
        uint256 /* _chainId */,
        uint256 /* _msgValue */,
        bytes32 /* _assetId */,
        address /* _originalCaller */,
        bytes calldata /* _data */
    ) external payable override returns (bytes memory) {
        return "";
    }

    /// @notice Accept ETH transfers
    receive() external payable {}
}
