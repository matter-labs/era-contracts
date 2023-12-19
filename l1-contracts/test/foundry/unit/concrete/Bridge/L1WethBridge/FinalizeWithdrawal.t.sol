// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1WethBridgeTest} from "./_L1WethBridge_Shared.t.sol";
import {Utils} from "../../Utils/Utils.sol";

contract FinalizeWithdrawalTest is L1WethBridgeTest {
    function test_RevertWhen_FinalizingWithdrawalWithWrongMessageLength() public {
        vm.expectRevert(bytes.concat("Incorrect ETH message with additional data length"));
        bridgeProxy.finalizeWithdrawal(0, 0, 0, bytes(""), new bytes32[](0));
    }

    function test_RevertWhen_FinalizingWithdrawalWithWrongFunctionSelector() public {
        bytes memory message = abi.encodePacked(
            bytes4(Utils.randomBytes32("functionSignature")), // function selector - 4 bytes
            bytes20(Utils.randomBytes32("l1EthWithdrawReceiver")), //  l1 eth withdraw receiver - 20 bytes
            bytes32(Utils.randomBytes32("ethAmount")), //  eth amount - 32 bytes
            bytes20(Utils.randomBytes32("l2Sender")), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1WethReceiver")) // l1 weth receiver - 20 bytes
        );

        vm.expectRevert(bytes.concat("Incorrect ETH message function selector"));
        bridgeProxy.finalizeWithdrawal(0, 0, 0, message, new bytes32[](0));
    }

    function test_RevertWhen_FinalizingWithdrawalWithWrongReceiver() public {
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            bytes20(Utils.randomBytes32("l1EthWithdrawReceiver")), //  l1 eth withdraw receiver - 20 bytes
            bytes32(Utils.randomBytes32("ethAmount")), //  eth amount - 32 bytes
            bytes20(Utils.randomBytes32("l2Sender")), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1WethReceiver")) // l1 weth receiver - 20 bytes
        );
        vm.expectRevert(bytes.concat(bytes.concat("Wrong L1 ETH withdraw receiver")));
        bridgeProxy.finalizeWithdrawal(0, 0, 0, message, new bytes32[](0));
    }

    function test_RevertWhen_FinalizingWithdrawalWithWrongL2Sender() public {
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            address(bridgeProxy), //  l1 eth withdraw receiver - 20 bytes
            bytes32(Utils.randomBytes32("ethAmount")), //  eth amount - 32 bytes
            bytes20(Utils.randomBytes32("l2Sender")), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1WethReceiver")) // l1 weth receiver - 20 bytes
        );
        vm.expectRevert(bytes.concat("The withdrawal was not initiated by L2 bridge"));
        bridgeProxy.finalizeWithdrawal(0, 0, 0, message, new bytes32[](0));
    }

    function test_RevertWhen_FinalisedAndUnsuccessfulProve() public {
        // finalised
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().isEthWithdrawalFinalized.selector),
            abi.encode(true)
        );
        // prove is unsuccessful
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().proveL2MessageInclusion.selector),
            abi.encode(false)
        );
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            address(bridgeProxy), //  l1 eth withdraw receiver - 20 bytes
            Utils.randomBytes32("eth amount"), //  eth amount - 32 bytes
            address(bridgeProxy.l2Bridge()), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1 weth receiver")) // l1 weth receiver - 20 bytes
        );

        vm.expectRevert(bytes.concat("vq"));
        bridgeProxy.finalizeWithdrawal(0, 0, 0, message, new bytes32[](0));
    }

    function test_SuccessfulAlreadyFinalizedAndSuccessfulProve() public {
        // finalised
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().isEthWithdrawalFinalized.selector),
            abi.encode(true)
        );
        // prove is successful
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().proveL2MessageInclusion.selector),
            abi.encode(true)
        );
        uint256 amount = 10000;

        uint256 l2BatchNumber = 0;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            address(bridgeProxy), //  l1 eth withdraw receiver - 20 bytes
            bytes32(amount), //  eth amount - 32 bytes
            address(bridgeProxy.l2Bridge()), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1 weth receiver")) // l1 weth receiver - 20 bytes
        );
        bytes32[] memory merkleProof = new bytes32[](0);

        // set the bridge's balance so it will be able to transfer funds
        vm.deal(address(bridgeProxy), amount);

        bridgeProxy.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, l2TxNumberInBatch, message, merkleProof);
        bool isFinalised = bridgeProxy.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex);
        assertTrue(isFinalised, "Withdrawal should be finalised");
    }

    function test_SuccessfulNotYetFinalized() public {
        // not yet finalized
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().isEthWithdrawalFinalized.selector),
            abi.encode(false)
        );
        // finalizeEthWithdrawal mock
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().finalizeEthWithdrawal.selector),
            abi.encode(true)
        );
        uint256 amount = 10000;

        uint256 l2BatchNumber = 0;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            address(bridgeProxy), //  l1 eth withdraw receiver - 20 bytes
            bytes32(amount), //  eth amount - 32 bytes
            address(bridgeProxy.l2Bridge()), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1 weth receiver")) // l1 weth receiver - 20 bytes
        );
        bytes32[] memory merkleProof = new bytes32[](0);

        // set the bridge's balance so it will be able to transfer funds
        vm.deal(address(bridgeProxy), amount);

        bridgeProxy.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, l2TxNumberInBatch, message, merkleProof);

        bool isFinalised = bridgeProxy.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex);
        assertTrue(isFinalised, "Withdrawal should be finalised");
    }

    function test_RevertWhen_AlreadyFinalized() public {
        // running finalizeWithdrawal twice should revert
        // not yet finalized
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().isEthWithdrawalFinalized.selector),
            abi.encode(false)
        );
        // finalizeEthWithdrawal mock
        vm.mockCall(
            address(bridgeProxy.zkSync()),
            abi.encodeWithSelector(bridgeProxy.zkSync().finalizeEthWithdrawal.selector),
            abi.encode(true)
        );
        uint256 amount = 10000;

        uint256 l2BatchNumber = 0;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes memory message = abi.encodePacked(
            functionSignature, // function selector - 4 bytes
            address(bridgeProxy), //  l1 eth withdraw receiver - 20 bytes
            bytes32(amount), //  eth amount - 32 bytes
            address(bridgeProxy.l2Bridge()), // l2 sender - 20 bytes
            bytes20(Utils.randomBytes32("l1 weth receiver")) // l1 weth receiver - 20 bytes
        );
        bytes32[] memory merkleProof = new bytes32[](0);

        // set the bridge's balance so it will be able to transfer funds
        vm.deal(address(bridgeProxy), amount);

        bridgeProxy.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, l2TxNumberInBatch, message, merkleProof);

        // trying to finalize it again should result in a revert
        vm.expectRevert(bytes.concat("Withdrawal is already finalized"));
        bridgeProxy.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, l2TxNumberInBatch, message, merkleProof);
    }
}
