// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

contract L1SharedBridgeTestBase is L1SharedBridgeTest {
    function test_bridgehubDepositBaseToken_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, ETH_TOKEN_ADDRESS, amount);
    }

    function test_bridgehubDepositBaseToken_Erc() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, address(token), amount);
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, address(token), amount);
    }

    function test_bridgehubDeposit_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            to: zkSync,
            l1Token: ETH_TOKEN_ADDRESS,
            amount: amount
        });
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Erc() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            to: zkSync,
            l1Token: address(token),
            amount: amount
        });
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubConfirmL2Transaction() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositFinalized(chainId, txDataHash, txHash);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_claimFailedDeposit_Erc() public {
        token.mint(address(sharedBridge), amount);
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");
        _setSharedBridgeChainBalance(chainId, address(token), amount);

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ClaimedFailedDepositSharedBridge({chainId: chainId, to: alice, l1Token: address(token), amount: amount});
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: address(token),
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDeposit_Eth() public {
        vm.deal(address(sharedBridge), amount);

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");
        _setSharedBridgeChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ClaimedFailedDepositSharedBridge({
            chainId: chainId,
            to: alice,
            l1Token: ETH_TOKEN_ADDRESS,
            amount: amount
        });
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: ETH_TOKEN_ADDRESS,
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth() public {
        vm.deal(address(sharedBridge), amount);

        _setSharedBridgeChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_ErcOnEth() public {
        token.mint(address(sharedBridge), amount);

        _setSharedBridgeChainBalance(chainId, address(token), amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnErc() public {
        vm.deal(address(sharedBridge), amount);

        _setSharedBridgeChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            ETH_TOKEN_ADDRESS,
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_BaseErcOnErc() public {
        token.mint(address(sharedBridge), amount);

        _setSharedBridgeChainBalance(chainId, address(token), amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_NonBaseErcOnErc() public {
        token.mint(address(sharedBridge), amount);

        _setSharedBridgeChainBalance(chainId, address(token), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.mockCall(bridgehubAddress, abi.encodeWithSelector(IBridgehub.baseToken.selector), abi.encode(address(2))); //alt base token
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTx() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.mockCall(
            eraDiamondProxy,
            abi.encodeWithSelector(IGetters.isEthWithdrawalFinalized.selector),
            abi.encode(false)
        );

        _setSharedBridgeChainBalance(eraChainId, ETH_TOKEN_ADDRESS, amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                eraChainId,
                legacyBatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(eraChainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }
}
