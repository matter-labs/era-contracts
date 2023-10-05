// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadMailboxTest} from "./_BridgeheadMailbox_Shared.t.sol";
import {IMailbox} from "../../../../../../cache/solpp-generated-contracts/bridgehead/chain-interfaces/IMailbox.sol";

/* solhint-enable max-line-length */

contract L2TransactionBaseCostTest is BridgeheadMailboxTest {
    uint256 internal gasPrice;
    uint256 internal l2GasLimit;
    uint256 internal l2GasPerPubdataByteLimit;

    function setUp() public {
        gasPrice = 123456789;
        l2GasLimit = 234567890;
        l2GasPerPubdataByteLimit = 345678901;
    }

    function test_RevertWhen_InternalCallReverts() public {
        bytes memory revertMessage = "random revert";

        vm.mockCallRevert(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(
                IMailbox.l2TransactionBaseCost.selector,
                gasPrice,
                l2GasLimit,
                l2GasPerPubdataByteLimit
            ),
            revertMessage
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(
                IMailbox.l2TransactionBaseCost.selector,
                gasPrice,
                l2GasLimit,
                l2GasPerPubdataByteLimit
            )
        );

        vm.expectRevert(revertMessage);
        bridgehead.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
    }

    function test_ShouldReturnReceivedCanonicalTxHash() public {
        uint256 expectedBaseCost = 123456789;

        vm.mockCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(
                IMailbox.l2TransactionBaseCost.selector,
                gasPrice,
                l2GasLimit,
                l2GasPerPubdataByteLimit
            ),
            abi.encode(expectedBaseCost)
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(
                IMailbox.l2TransactionBaseCost.selector,
                gasPrice,
                l2GasLimit,
                l2GasPerPubdataByteLimit
            )
        );

        uint256 baseCost = bridgehead.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
        assertEq(baseCost, expectedBaseCost);
    }
}
