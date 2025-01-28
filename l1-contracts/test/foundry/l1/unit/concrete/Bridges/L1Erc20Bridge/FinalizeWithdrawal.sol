// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {WithdrawalAlreadyFinalized} from "contracts/common/L1ContractErrors.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";

contract FinalizeWithdrawalTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    event WithdrawalFinalized(address indexed to, address indexed l1Token, uint256 amount);

    function test_RevertWhen_withdrawalFinalized() public {
        uint256 l2BatchNumber = 0;
        uint256 l2MessageIndex = 1;
        stdstore
            .target(address(bridge))
            .sig("isWithdrawalFinalized(uint256,uint256)")
            .with_key(l2BatchNumber)
            .with_key(l2MessageIndex)
            .checked_write(true);

        assertTrue(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));

        vm.expectRevert(WithdrawalAlreadyFinalized.selector);
        bytes32[] memory merkleProof;
        bridge.finalizeWithdrawal({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: 0,
            _message: "",
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawalSuccessfully() public {
        uint256 l2BatchNumber = 3;
        uint256 l2MessageIndex = 4;
        uint256 txNumberInBatch = 0;
        bytes32[] memory merkleProof;
        uint256 amount = 999;

        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));
        FinalizeL1DepositParams memory finalizeWithdrawalParams = FinalizeL1DepositParams({
            chainId: eraChainId,
            l2BatchNumber: l2BatchNumber,
            l2MessageIndex: l2MessageIndex,
            l2Sender: L2_ASSET_ROUTER_ADDR,
            l2TxNumberInBatch: uint16(txNumberInBatch),
            message: "",
            merkleProof: merkleProof
        });
        vm.mockCall(
            l1NullifierAddress,
            abi.encodeWithSelector(IL1Nullifier.finalizeDeposit.selector, finalizeWithdrawalParams),
            abi.encode(alice, address(token), amount)
        );
        address l2BridgeAddress = address(12);
        vm.mockCall(
            l1NullifierAddress,
            abi.encodeWithSelector(IL1Nullifier.l2BridgeAddress.selector, eraChainId),
            abi.encode(l2BridgeAddress)
        );

        vm.prank(alice);
        // solhint-disable-next-line func-named-parameters
        // vm.expectEmit(true, true, true, true, address(bridge));
        // emit WithdrawalFinalized(alice, address(token), amount);

        bridge.finalizeWithdrawal({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: 0,
            _message: "",
            _merkleProof: merkleProof
        });

        // withdrawal finalization should be handled in the shared bridge, so it shouldn't
        // change in the  L1 ERC20 bridge after finalization.
        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));
    }
}
