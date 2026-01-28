// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";

import {L1AssetRouterTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";

contract L1AssetRouterLegacyTest is L1AssetRouterTest {
    function test_depositLegacyERC20Bridge() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit LegacyDepositInitiated({
            chainId: eraChainId,
            l2DepositTxHash: txHash,
            from: alice,
            to: bob,
            l1Token: address(token),
            amount: amount
        });

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IL1Bridgehub.requestL2TransactionDirect.selector),
            abi.encode(txHash)
        );

        vm.prank(l1ERC20BridgeAddress);

        sharedBridge.depositLegacyErc20Bridge({
            _originalCaller: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: refundRecipient
        });
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_EthOnEth() public {
        vm.deal(address(sharedBridge), amount);

        /// storing chainBalance
        _setAssetTrackerChainBalance(eraChainId, ETH_TOKEN_ADDRESS, amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            messageRootAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IMessageVerification.proveL2MessageInclusionShared.selector,
                eraChainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(eraChainId, ETH_TOKEN_ASSET_ID, message);
        vm.prank(l1ERC20BridgeAddress);
        FinalizeL1DepositParams memory finalizeWithdrawalParams = FinalizeL1DepositParams({
            chainId: eraChainId,
            l2BatchNumber: l2BatchNumber,
            l2MessageIndex: l2MessageIndex,
            l2Sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            l2TxNumberInBatch: l2TxNumberInBatch,
            message: message,
            merkleProof: merkleProof
        });
        l1Nullifier.finalizeDeposit(finalizeWithdrawalParams);
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_ErcOnEth() public {
        /// storing chainBalance
        _setAssetTrackerChainBalance(eraChainId, address(token), amount);

        // solhint-disable-next-line func-named-parameters
        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_ASSET_ROUTER_ADDR,
            data: message
        });

        vm.mockCall(
            messageRootAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IMessageVerification.proveL2MessageInclusionShared.selector,
                eraChainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );
        // console.log(sharedBridge.)
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(tokenAssetId, isWithdrawalFinalizedStorageLocation + 2)),
            bytes32(uint256(uint160(address(nativeTokenVault))))
        );
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, false, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(eraChainId, tokenAssetId, new bytes(0));
        vm.prank(l1ERC20BridgeAddress);
        FinalizeL1DepositParams memory finalizeWithdrawalParams = FinalizeL1DepositParams({
            chainId: eraChainId,
            l2BatchNumber: l2BatchNumber,
            l2MessageIndex: l2MessageIndex,
            l2Sender: L2_ASSET_ROUTER_ADDR,
            l2TxNumberInBatch: l2TxNumberInBatch,
            message: message,
            merkleProof: merkleProof
        });
        l1Nullifier.finalizeDeposit(finalizeWithdrawalParams);
    }
}
