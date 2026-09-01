// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";
import {INITIAL_DEPOSIT_AMOUNT, INITIAL_WITHDRAWAL_AMOUNT, L1_TOKEN_ADDRESS} from "../common/Constants.sol";

import {SharedL2ContractL1Deployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1Deployer.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract AssetRouterTest is SharedL2ContractL1Deployer, AssetRouter_ActorHandler_Deployer {
    function setUp() public virtual override {
        super.setUp();

        l1AssetRouterActorHandler.finalizeDeposit(INITIAL_DEPOSIT_AMOUNT, address(this), 0);
        userActorHandlers[0].withdraw(INITIAL_WITHDRAWAL_AMOUNT, address(this));
    }

    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        super.deployL2Contracts(_l1ChainId);
        deployActorHandlers();
    }

    function test_DepositAndWithdrawalSmoke() public {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        assertGt(l2TokenAddress.code.length, 0, "deposit must deploy the bridged token");
        BridgedStandardERC20 l2Token = BridgedStandardERC20(l2TokenAddress);

        uint256 depositsBefore = l1AssetRouterActorHandler.ghost_totalDeposits();
        uint256 withdrawalsBefore = userActorHandlers[0].ghost_totalWithdrawalAmount();
        uint256 withdrawalCallsBefore = userActorHandlers[0].ghost_totalFunctionCalls();
        uint256 balanceBefore = l2Token.balanceOf(address(userActorHandlers[0]));

        assertEq(depositsBefore, INITIAL_DEPOSIT_AMOUNT, "setup must record its deposit");
        assertEq(withdrawalsBefore, INITIAL_WITHDRAWAL_AMOUNT, "setup must record its withdrawal");
        assertEq(withdrawalCallsBefore, 1, "setup must record one successful withdrawal call");
        assertEq(
            balanceBefore,
            INITIAL_DEPOSIT_AMOUNT - INITIAL_WITHDRAWAL_AMOUNT,
            "setup must leave the unwithdrawn bridged-token balance"
        );

        l1AssetRouterActorHandler.finalizeDeposit(INITIAL_DEPOSIT_AMOUNT, address(this), 0);

        assertEq(
            l1AssetRouterActorHandler.ghost_totalDeposits(),
            depositsBefore + INITIAL_DEPOSIT_AMOUNT,
            "deposit handler must record a successful deposit"
        );
        assertEq(
            l2Token.balanceOf(address(userActorHandlers[0])),
            balanceBefore + INITIAL_DEPOSIT_AMOUNT,
            "deposit must mint the bridged token"
        );

        userActorHandlers[0].withdraw(INITIAL_WITHDRAWAL_AMOUNT, address(this));

        assertEq(
            userActorHandlers[0].ghost_totalWithdrawalAmount(),
            withdrawalsBefore + INITIAL_WITHDRAWAL_AMOUNT,
            "withdrawal handler must record a successful withdrawal"
        );
        assertEq(
            userActorHandlers[0].ghost_totalFunctionCalls(),
            withdrawalCallsBefore + 1,
            "withdrawal handler must record a successful call"
        );
        assertEq(
            l2Token.balanceOf(address(userActorHandlers[0])),
            balanceBefore + INITIAL_DEPOSIT_AMOUNT - INITIAL_WITHDRAWAL_AMOUNT,
            "withdrawal must burn the bridged token"
        );
    }
}
