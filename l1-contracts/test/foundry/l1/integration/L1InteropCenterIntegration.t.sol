// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BridgehubInvariantTests} from "./BridgehubTests.t.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DepositDoesNotExist} from "contracts/common/L1ContractErrors.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

contract L1InteropCenterIntegrationTest is BridgehubInvariantTests {
    function setUp() public {
        prepare();
    }

    function test_indirectDepositRecordsCanonicalHashAndRecovers() public {
        uint256 chainId = zkChainIds[0];
        assertEq(getZKChainBaseToken(chainId), ETH_TOKEN_ADDRESS);
        address caller = users[0];
        TestnetERC20Token token = TestnetERC20Token(tokens[0]);
        uint256 amount = 1 ether;
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        bytes memory transferData = DataEncoding.encodeBridgeBurnData(amount, caller, address(token));
        bytes memory payload = bytes.concat(NEW_ENCODING_VERSION, abi.encode(assetId, transferData));
        uint256 mintValue = addresses.interopCenter.l2TransactionBaseCost(
            chainId,
            tx.gasprice,
            1_000_000,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (mintValue, 1_000_000, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, caller)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        token.mint(caller, amount);
        vm.deal(caller, mintValue);
        vm.startPrank(caller);
        token.approve(address(addresses.l1NativeTokenVault), amount);
        vm.recordLogs();
        bytes32 canonicalHash = addresses.interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(chainId, address(addresses.sharedBridge)),
            payload,
            attributes
        );
        vm.stopPrank();
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(vm.getRecordedLogs());
        assertEq(canonicalHash, request.txHash);
        assertEq(token.balanceOf(caller), 0);
        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), amount);
        bytes32 dataHash = DataEncoding.encodeTxDataHash(caller, assetId, transferData);
        assertEq(addresses.l1Nullifier.depositHappened(chainId, canonicalHash), dataHash);

        // Isolate the L2 failure proof: all L1 funding, queueing, confirmation and recovery calls are real.
        vm.mockCall(
            address(addresses.bridgehub.messageRoot()),
            abi.encodeWithSelector(IMessageVerification.proveL1ToL2TransactionStatusShared.selector),
            abi.encode(true)
        );
        vm.expectEmit(true, true, false, true, address(addresses.sharedBridge));
        emit IL1AssetRouter.ClaimedFailedDepositAssetRouter(chainId, assetId, transferData);
        addresses.l1Nullifier.bridgeRecoverFailedTransfer(
            chainId,
            caller,
            assetId,
            transferData,
            canonicalHash,
            1,
            0,
            0,
            new bytes32[](0)
        );
        assertEq(token.balanceOf(caller), amount);
        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), 0);
        assertEq(addresses.l1Nullifier.depositHappened(chainId, canonicalHash), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DepositDoesNotExist.selector, bytes32(0), dataHash));
        addresses.l1Nullifier.bridgeRecoverFailedTransfer(
            chainId,
            caller,
            assetId,
            transferData,
            canonicalHash,
            1,
            0,
            0,
            new bytes32[](0)
        );
    }

    function test_directAndIndirectFundingMatrix() public {
        for (uint256 chain = 0; chain < zkChainIds.length; ++chain) {
            depositEthToBridgeSuccess(0, chain, 1 ether);
            depositERC20ToBridgeSuccess(0, chain, 0, 1 ether);
            depositERC20ToBridgeSuccess(0, chain, 1, 1 ether);
        }
    }

    function test_directEthPriorityTransaction() public {
        for (uint256 i = 0; i < zkChainIds.length; ++i) {
            if (getZKChainBaseToken(zkChainIds[i]) == ETH_TOKEN_ADDRESS) {
                depositEthToBridgeSuccess(0, i, 1 ether);
                return;
            }
        }
        assertTrue(false, "ETH-base chain missing from integration harness");
    }
}
