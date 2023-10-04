// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadMailboxTest} from "./_BridgeheadMailbox_Shared.t.sol";
import {IChainGetters} from "../../../../../../cache/solpp-generated-contracts/bridgehead/chain-interfaces/IChainGetters.sol";

/* solhint-enable max-line-length */

contract IsEthWithdrawalFinalizedTest is BridgeheadMailboxTest {
    uint256 internal l2MessageIndex;
    uint256 internal l2TxNumberInBlock;

    function setUp() public {
        l2MessageIndex = 123456789;
        l2TxNumberInBlock = 23456;
    }

    function test_WhenChainContractReturnsTrue() public {
        vm.mockCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(IChainGetters.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock),
            abi.encode(true)
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(IChainGetters.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock)
        );

        bool res = bridgehead.isEthWithdrawalFinalized(chainId, l2MessageIndex, l2TxNumberInBlock);
        assertEq(res, true, "ETH withdrawal should be finalized");
    }

    function test_WhenChainContractReturnsFalse() public {
        vm.mockCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(IChainGetters.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock),
            abi.encode(false)
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            abi.encodeWithSelector(IChainGetters.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock)
        );

        bool res = bridgehead.isEthWithdrawalFinalized(chainId, l2MessageIndex, l2TxNumberInBlock);
        assertEq(res, false, "ETH withdrawal should not be finalized");
    }
}
