// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {BridgehubBurnCTMAssetData, IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IncorrectChainAssetId} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {TxStatus} from "contracts/common/Messaging.sol";

/// @notice `bridgeConfirmTransferResult` names the chain in its transfer data, while the asset router picks the
/// handler by asset ID. Another asset's handler can be pointed here, so the asset must be that chain's CTM asset,
/// as `bridgeBurn` already requires.
/// @dev Runs against a real `L1ChainAssetHandler` deployed directly. The Bridgehub is mocked for the lookups the
///      check makes before it would forward anything; the migration flow itself is covered by the integration
///      suites.
contract L1ChainAssetHandlerConfirmTransferResultTest is Test {
    uint256 internal constant CHAIN_ID = 271;

    L1ChainAssetHandler internal handler;
    address internal owner = makeAddr("owner");
    address internal bridgehub = makeAddr("bridgehub");
    address internal assetRouter = makeAddr("assetRouter");
    bytes32 internal ctmAssetId = keccak256("the chain's CTM asset");

    function setUp() public {
        handler = new L1ChainAssetHandler(owner, bridgehub);
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(makeAddr("messageRoot")));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.prank(owner);
        handler.setAddresses();

        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.ctmAssetIdFromChainId, (CHAIN_ID)),
            abi.encode(ctmAssetId)
        );
    }

    function test_revertWhen_confirmingAnotherAssetForTheChain() public {
        bytes32 otherAssetId = keccak256("another asset");
        bytes memory transferData = abi.encode(
            BridgehubBurnCTMAssetData({chainId: CHAIN_ID, ctmData: bytes(""), chainData: bytes("")})
        );

        // Nothing is forwarded to the Bridgehub: the check comes first.
        vm.expectCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.forwardedBridgeConfirmTransferResult.selector),
            0
        );
        vm.prank(assetRouter);
        vm.expectRevert(abi.encodeWithSelector(IncorrectChainAssetId.selector, otherAssetId, ctmAssetId));
        handler.bridgeConfirmTransferResult(0, TxStatus.Success, otherAssetId, makeAddr("depositor"), transferData);
    }
}
