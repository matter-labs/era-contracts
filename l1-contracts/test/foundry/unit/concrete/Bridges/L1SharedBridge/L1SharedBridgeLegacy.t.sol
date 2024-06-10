// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DummyHyperchain} from "contracts/dev-contracts/test/DummyHyperchain.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

contract L1SharedBridgeLegacyTest is L1SharedBridgeTest {
    function test_transferFundsFromLegacy_zeroETHTransferred() public {
        address targetDiamond = makeAddr("target diamond");
        uint256 targetChainId = 31337;

        vm.mockCall(targetDiamond, abi.encodeWithSelector(IMailbox.transferEthToSharedBridge.selector), "");

        vm.expectRevert("ShB: 0 eth transferred");
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(ETH_TOKEN_ADDRESS, targetDiamond, targetChainId);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
    }

    function test_transferFundsFromLegacy_zeroTokenTransferred() public {
        address targetDiamond = makeAddr("target diamond");
        uint256 targetChainId = 31337;
        address tokenAddress = address(token);

        vm.mockCall(targetDiamond, abi.encodeWithSelector(IMailbox.transferEthToSharedBridge.selector), "");

        vm.expectRevert("ShB: 0 amount to transfer");
        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(tokenAddress, targetDiamond, targetChainId);
        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), 0);
    }

    function test_transferFundsFromLegacy_wrongAmount(uint256 amount) public {
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

    function test_transferTokenFundsFromLegacy_ERC(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        token.mint(l1ERC20BridgeAddress, amount);
        address tokenAddress = address(token);
        assertEq(token.balanceOf(l1ERC20BridgeAddress), amount);

        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(tokenAddress, l1ERC20BridgeAddress, eraChainId);

        assertEq(token.balanceOf(l1ERC20BridgeAddress), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, tokenAddress), amount);
        assertEq(token.balanceOf(address(sharedBridge)), amount);
    }

    function test_transferFundsFromLegacy_ETH(uint256 amount) public {
        DummyHyperchain hyperchain = new DummyHyperchain(bridgehubAddress, eraChainId);
        hyperchain.setBaseTokenBridge(address(sharedBridge));
        hyperchain.setChainId(eraChainId);
        address hyperchainAddress = address(hyperchain);

        amount = bound(amount, 1, type(uint256).max);
        vm.deal(hyperchainAddress, amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, eraChainId),
            abi.encode(hyperchainAddress)
        );

        vm.prank(owner);
        sharedBridge.transferFundsFromLegacy(ETH_TOKEN_ADDRESS, hyperchainAddress, eraChainId);

        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), amount);
        assertEq(address(sharedBridge).balance, amount);
        assertEq(hyperchainAddress.balance, 0);
    }

    function test_depositLegacyERC20Bridge_ERC() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
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

        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), amount);
        assertEq(sharedBridge.depositHappened(eraChainId, txHash), txDataHash);
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_EthOnEth_postUgrade() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        __finalizeWithdrawalLegacyErc20Bridge(ETH_TOKEN_ADDRESS, l2BatchNumber);

        assertEq(alice.balance, amount);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
        assertEq(address(sharedBridge).balance, 0);
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_ErcOnEth_postUpgrade() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        __finalizeWithdrawalLegacyErc20Bridge(address(token), l2BatchNumber);

        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
        assertEq(token.balanceOf(address(sharedBridge)), 0);
    }

    /// version which is called by legacy bridge and goes through the statements
    /// and return legacy withdraw
    function test_finalizeWithdrawalLegacyErc20Bridge_EthOnEth_preUpgrade() public {
        vm.prank(owner);
        // post ugrade first batch is 1
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);

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

        // 0 is legacy batch number
        __finalizeWithdrawalLegacyErc20Bridge(ETH_TOKEN_ADDRESS, 0);

        assertEq(alice.balance, amount);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
        assertEq(address(sharedBridge).balance, 0);
    }

    /// version which is called by legacy bridge and goes through the statements
    /// and return legacy deposit
    function test_finalizeWithdrawalLegacyErc20Bridge_ErcOnEth_preUpgrade() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);

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
        // 0 is legacy batch number
        __finalizeWithdrawalLegacyErc20Bridge(address(token), 0);

        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
        assertEq(token.balanceOf(address(sharedBridge)), 0);
    }

    function __finalizeWithdrawalLegacyErc20Bridge(address _token, uint256 _batchNumber) internal {
        if (_token == ETH_TOKEN_ADDRESS) {
            vm.deal(address(sharedBridge), amount);
        } else {
            token.mint(address(sharedBridge), amount);
        }

        _setSharedBridgeChainBalance(eraChainId, _token, amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message;

        if (_token == ETH_TOKEN_ADDRESS) {
            message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);

        } else {
            message = abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, alice, _token, amount);
        }

        address sender;
        if (_token == ETH_TOKEN_ADDRESS) {
            sender = L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        } else {
            sender = l2SharedBridge;
        }

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: sender,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                eraChainId,
                _batchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(eraChainId, alice, _token, amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge({
            _l2BatchNumber: _batchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDepositLegacyErc20Bridge_Erc() public {
        vm.prank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(1, 0);

        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _claimFailedDepositLegacy(address(token), l2BatchNumber, l2TxNumberInBatch, txDataHash);

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.depositHappened(eraChainId, txHash), bytes32(0));
    }

    function test_claimFailedDepositLegacyErc20Bridge_batchBeforeUpdate(uint256 eraLegacyLastDepositBatch) public {
        // minimum 1 to allow for batch number to be at least 0
        eraLegacyLastDepositBatch = bound(eraLegacyLastDepositBatch, 1, type(uint256).max);

        // initialize last era legacy bridge deposit batch to eraLegacyLastDepositBatch
        // set last deposit tx number to 0 (it is not required in this test)
        vm.prank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(eraLegacyLastDepositBatch, 0);

        // bound batch number to be at most eraLegacyLastDepositBatch - 1
        l2BatchNumber = bound(eraLegacyLastDepositBatch, 0, eraLegacyLastDepositBatch - 1);

        // we don't need to store deposit hashes for this test
        // but we store to check whether hash was not deleted
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _claimFailedDepositLegacy(address(token), l2BatchNumber, 0, txDataHash);

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.depositHappened(eraChainId, txHash), txDataHash);
    }

    function test_claimFailedDepositLegacyErc20Bridge_txBeforeUpdate(
        uint256 eraLegacyLastDepositBatch,
        uint256 eraLegacyBridgeLastDepositTxNumber
    ) public {
        // minimum 1 to allow for tx number in batch to be at least 0
        eraLegacyLastDepositBatch = bound(eraLegacyLastDepositBatch, 1, type(uint256).max);
        eraLegacyBridgeLastDepositTxNumber = bound(eraLegacyBridgeLastDepositTxNumber, 1, type(uint16).max);

        vm.prank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(eraLegacyLastDepositBatch, eraLegacyBridgeLastDepositTxNumber);

        // bound tx number in batch to be at most eraLegacyBridgeLastDepositTxNumber - 1
        l2BatchNumber = eraLegacyLastDepositBatch;
        l2TxNumberInBatch = uint16(
            bound(eraLegacyBridgeLastDepositTxNumber, 0, eraLegacyBridgeLastDepositTxNumber - 1)
        );

        // we don't need to store deposit hashes for this test
        // but we store to check whether hash was not deleted
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _claimFailedDepositLegacy(address(token), l2BatchNumber, l2TxNumberInBatch, txDataHash);

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.depositHappened(eraChainId, txHash), txDataHash);
    }

    function _claimFailedDepositLegacy(
        address _token,
        uint256 _l2BatchNumber,
        uint16 _l2TxNumberInBatch,
        bytes32 _txDataHash
    ) internal {
        if (_token == ETH_TOKEN_ADDRESS) {
            vm.deal(address(sharedBridge), amount);
        } else {
            token.mint(address(sharedBridge), amount);
        }

        _setSharedBridgeDepositHappened(eraChainId, txHash, _txDataHash);
        require(sharedBridge.depositHappened(eraChainId, txHash) == _txDataHash, "Deposit not set");
        _setSharedBridgeChainBalance(eraChainId, _token, amount);

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                eraChainId,
                txHash,
                _l2BatchNumber,
                l2MessageIndex,
                _l2TxNumberInBatch,
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
            _l1Token: _token,
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }
}
