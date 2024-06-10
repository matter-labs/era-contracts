// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "contracts/common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IL2Bridge} from "contracts/bridge/interfaces/IL2Bridge.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract L1SharedBridgeTestBase is L1SharedBridgeTest {
    function test_pause(address amount) public {
        vm.prank(owner);
        sharedBridge.pause();
        assertTrue(sharedBridge.paused());

        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));

        vm.expectRevert("Pausable: paused");
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);

        vm.prank(owner);
        sharedBridge.unpause();
        assertFalse(sharedBridge.paused());
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_receiveEth(uint256 amount) public {
        address stmAddress = makeAddr("stm");

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, eraChainId),
            abi.encode(stmAddress)
        );

        vm.deal(stmAddress, amount);
        vm.prank(stmAddress);
        sharedBridge.receiveEth{value: amount}(eraChainId);

        assertEq(address(stmAddress).balance, 0);

        assertEq(address(sharedBridge).balance, amount);
        assertEq(stmAddress.balance, 0);
    }

    function test_bridgehubDepositBaseToken_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, ETH_TOKEN_ADDRESS, amount);

        assertEq(address(sharedBridge).balance, amount);
        assertEq(sharedBridge.chainBalance(chainId, ETH_TOKEN_ADDRESS), amount);
        assertEq(alice.balance, 0);
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

        assertEq(token.balanceOf(address(sharedBridge)), amount);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), amount);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function _getERC20Getters(address _token) internal view returns (bytes memory) {
        if (_token == ETH_TOKEN_ADDRESS) {
            bytes memory name = bytes("Ether");
            bytes memory symbol = bytes("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }

    function test_bridgehubDeposit_Eth(uint256 amount) public {
        // bound to avoid empty deposit assert
        amount = bound(amount, 1, type(uint256).max);

        vm.deal(bridgehubAddress, amount);

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
            to: bob,
            l1Token: ETH_TOKEN_ADDRESS,
            amount: amount
        });
 
        vm.prank(bridgehubAddress);
        L2TransactionRequestTwoBridgesInner memory txRequest = sharedBridge.bridgehubDeposit{value: amount}(
            chainId,
            alice,
            0,
            abi.encode(ETH_TOKEN_ADDRESS, 0, bob)
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (alice, bob, ETH_TOKEN_ADDRESS, amount, _getERC20Getters(ETH_TOKEN_ADDRESS))
        );

        assertEq(txRequest.magicValue, TWO_BRIDGES_MAGIC_VALUE);
        assertEq(txRequest.l2Contract, l2SharedBridge);
        assertEq(txRequest.l2Calldata, l2Calldata);
        assertEq(txRequest.factoryDeps.length, 0);
        assertEq(txRequest.txDataHash, txDataHash);

        assertEq(address(sharedBridge).balance, amount);
        assertEq(sharedBridge.chainBalance(chainId, ETH_TOKEN_ADDRESS), amount);
        assertEq(alice.balance, 0);
    }

    function test_bridgehubDeposit_Erc(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);

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
            to: bob,
            l1Token: address(token),
            amount: amount
        });
        vm.prank(bridgehubAddress);

        L2TransactionRequestTwoBridgesInner memory txRequest = sharedBridge.bridgehubDeposit(
            chainId,
            alice,
            0,
            abi.encode(address(token), amount, bob)
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (alice, bob, address(token), amount, _getERC20Getters(address(token)))
        );

        assertEq(txRequest.magicValue, TWO_BRIDGES_MAGIC_VALUE);
        assertEq(txRequest.l2Contract, l2SharedBridge);
        assertEq(txRequest.l2Calldata, l2Calldata);
        assertEq(txRequest.factoryDeps.length, 0);
        assertEq(txRequest.txDataHash, txDataHash);

        assertEq(token.balanceOf(address(sharedBridge)), amount);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), amount);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_bridgehubConfirmL2Transaction() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositFinalized(chainId, txDataHash, txHash);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);

        assertEq(sharedBridge.depositHappened(chainId, txHash), txDataHash);
    }

    function test_setL1Erc20Bridge() public {
        address bridge = makeAddr("bridge");
        L1SharedBridge sharedBridgeImpl = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });

        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner)
        );
        L1SharedBridge sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));

        vm.prank(owner);
        sharedBridge.setL1Erc20Bridge(bridge);
        assertEq(address(sharedBridge.legacyBridge()), bridge);
    }

    function test_claimFailedDeposit_Erc() public {
        require(token.balanceOf(alice) == 0);
        token.mint(address(sharedBridge), amount);
        require(token.balanceOf(address(sharedBridge)) == amount);
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

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(token.balanceOf(alice), amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), 0);
        assertEq(sharedBridge.depositHappened(chainId, txHash), bytes32(0));
    }

    function test_claimFailedDeposit_Eth() public {
        require(alice.balance == 0);
        vm.deal(address(sharedBridge), amount);
        require(address(sharedBridge).balance == amount);
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

        assertEq(address(sharedBridge).balance, 0);
        assertEq(alice.balance, amount);

        assertEq(alice.balance, amount);
        assertEq(address(sharedBridge).balance, 0);
        assertEq(sharedBridge.chainBalance(chainId, ETH_TOKEN_ADDRESS), 0);
        assertEq(sharedBridge.depositHappened(chainId, txHash), bytes32(0));
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

        assertEq(address(sharedBridge).balance, 0);
        assertEq(alice.balance, amount);
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

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(token.balanceOf(alice), amount);
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

        assertEq(address(sharedBridge).balance, 0);
        assertEq(alice.balance, amount);
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

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(token.balanceOf(alice), amount);
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

        assertEq(token.balanceOf(address(sharedBridge)), 0);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTx() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
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

        assertEq(address(sharedBridge).balance, 0);
        assertEq(sharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), 0);
        assertEq(alice.balance, amount);
    }
}
