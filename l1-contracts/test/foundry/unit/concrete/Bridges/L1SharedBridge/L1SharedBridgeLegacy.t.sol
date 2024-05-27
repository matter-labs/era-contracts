// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DummyMailbox} from "contracts/dev-contracts/test/DummyMailbox.sol";
import {DummyL1ERC20Bridge} from "contracts/dev-contracts/test/DummyErc20Bridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract L1SharedBridgeLegacyTest is L1SharedBridgeTest {
    function test_transferFundsFromLegacyZeroETHTransferred() public {
        address targetDiamond = makeAddr("target diamond");
        uint256 targetChainId = 31337;

        vm.mockCall(targetDiamond, abi.encodeWithSelector(IMailbox.transferEthToSharedBridge.selector), "");

        vm.expectRevert("ShB: 0 eth transferred");
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(ETH_TOKEN_ADDRESS, targetDiamond, targetChainId);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
    }

    function test_transferFundsFromLegacyZeroTokenTransferred() public {
        address targetDiamond = makeAddr("target diamond");
        uint256 targetChainId = 31337;
        address tokenAddress = address(token);

        vm.mockCall(targetDiamond, abi.encodeWithSelector(IMailbox.transferEthToSharedBridge.selector), "");

        vm.expectRevert("ShB: 0 amount to transfer");
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(tokenAddress, targetDiamond, targetChainId);
        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), 0);
    }

    function test_transferTokenFundsFromLegacy(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        token.mint(l1ERC20BridgeAddress, amount);
        address tokenAddress = address(token);
        assertEq(token.balanceOf(l1ERC20BridgeAddress), amount);

        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), 0);
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(tokenAddress, l1ERC20BridgeAddress, eraChainId);
        assertEq(token.balanceOf(l1ERC20BridgeAddress), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), amount);
    }

    function test_transferFundsFromLegacyWrongAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max - 1);
        token.mint(l1ERC20BridgeAddress, amount);
        address tokenAddress = address(token);
        assertEq(token.balanceOf(l1ERC20BridgeAddress), amount);

        vm.mockCall(
            tokenAddress,
            abi.encodeWithSelector(IERC20.transfer.selector, address(sharedBridge), amount),
            abi.encode(true)
        );

        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), 0);

        vm.expectRevert("ShB: wrong amount transferred");
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(tokenAddress, l1ERC20BridgeAddress, 9);
        assertEq(token.balanceOf(l1ERC20BridgeAddress), amount);
        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), 0);
    }

    function test_transferETHFundsFromLegacy(uint256 amount) public {
        DummyMailbox mailbox = new DummyMailbox(address(sharedBridge));
        address mailboxAddress = address(mailbox);

        amount = bound(amount, 1, type(uint256).max);
        vm.deal(mailboxAddress, amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, eraChainId),
            abi.encode(mailboxAddress)
        );

        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(ETH_TOKEN_ADDRESS, mailboxAddress, 9);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), amount);
    }

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
            abi.encodeWithSelector(IBridgehub.requestL2TransactionDirect.selector),
            abi.encode(txHash)
        );

        vm.prank(l1ERC20BridgeAddress);

        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: refundRecipient
        });
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_EthOnEth() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.deal(address(sharedBridge), amount);

        /// storing chainBalance
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
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(eraChainId, alice, ETH_TOKEN_ADDRESS, amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_ErcOnEth() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        token.mint(address(sharedBridge), amount);

        /// storing chainBalance
        _setSharedBridgeChainBalance(eraChainId, address(token), amount);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        // solhint-disable-next-line func-named-parameters
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
                eraChainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(eraChainId, alice, address(token), amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDepositLegacyErc20Bridge_Erc() public {
        vm.prank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(1, 0);
        token.mint(address(sharedBridge), amount);

        // storing depositHappened[chainId][l2TxHash] = txDataHash.
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(eraChainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(eraChainId, txHash) == txDataHash, "Deposit not set");

        _setSharedBridgeChainBalance(eraChainId, address(token), amount);

        // Bridgehub bridgehub = new Bridgehub();
        // vm.store(address(bridgehub),  bytes32(uint256(5 +2)), bytes32(uint256(31337)));
        // require(address(bridgehub.deployer()) == address(31337), "Bridgehub: deployer wrong");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                eraChainId,
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
        emit ClaimedFailedDepositSharedBridge(eraChainId, alice, address(token), amount);
        vm.prank(l1ERC20BridgeAddress);

        sharedBridge.claimFailedDepositLegacyErc20Bridge({
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
}
