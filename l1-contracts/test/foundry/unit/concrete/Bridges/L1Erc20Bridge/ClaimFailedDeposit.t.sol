// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {EmptyDeposit} from "contracts/common/L1ContractErrors.sol";

contract ClaimFailedDepositTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

    function test_RevertWhen_ClaimAmountIsZero() public {
        vm.expectRevert(EmptyDeposit.selector);
        bytes32[] memory merkleProof;

        bridge.claimFailedDeposit({
            _depositSender: randomSigner,
            _l1Token: address(token),
            _l2TxHash: bytes32(""),
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: merkleProof
        });
    }
}
