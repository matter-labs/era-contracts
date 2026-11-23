// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

/// @dev The L2 side of a forced withdrawal: an L1 -> L2 priority transaction from the token holder calls one of the
/// L2 asset router's withdrawal functions, which the Era maintenance filterer lets through in `WITHDRAWALS_ONLY` mode.
/// The holder can't send any other transaction first, such as an `approve`, unless the chain admin allows it.
abstract contract L2ForcedWithdrawalTestAbstract is Test, SharedL2ContractDeployer {
    uint256 internal constant STUCK_AMOUNT = 100;

    address internal holder = makeAddr("holder");
    address internal l1Receiver = makeAddr("l1Receiver");

    /// @dev Bridges `STUCK_AMOUNT` of the L1 token to `holder` and returns its L2 address.
    function _depositToHolder() internal returns (BridgedStandardERC20 l2Token) {
        performDeposit(makeAddr("depositor"), holder, STUCK_AMOUNT);
        l2Token = BridgedStandardERC20(
            IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS)
        );
        assertEq(l2Token.balanceOf(holder), STUCK_AMOUNT);
        assertEq(l2Token.allowance(holder, L2_NATIVE_TOKEN_VAULT_ADDR), 0);
    }

    /// @dev A token bridged from L1 is burned from the holder with `bridgeBurn`, so no allowance is needed.
    function test_forcedWithdrawalOfBridgedTokenNeedsNoAllowance() public {
        BridgedStandardERC20 l2Token = _depositToHolder();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, L1_TOKEN_ADDRESS);
        bytes memory assetData = DataEncoding.encodeBridgeBurnData(STUCK_AMOUNT, l1Receiver, address(l2Token));

        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector)
        );
        vm.expectEmit(L2_ASSET_ROUTER_ADDR);
        emit IL2AssetRouter.WithdrawalInitiatedAssetRouter(L1_CHAIN_ID, holder, assetId, assetData);
        vm.prank(holder);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(assetId, assetData);

        assertEq(l2Token.balanceOf(holder), 0);
        assertEq(l2Token.totalSupply(), 0);
    }

    /// @dev The legacy `withdraw(address,address,uint256)` takes the same burn path.
    function test_legacyForcedWithdrawalOfBridgedTokenNeedsNoAllowance() public {
        BridgedStandardERC20 l2Token = _depositToHolder();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, L1_TOKEN_ADDRESS);

        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector)
        );
        vm.expectEmit(L2_ASSET_ROUTER_ADDR);
        emit IL2AssetRouter.WithdrawalInitiatedAssetRouter(
            L1_CHAIN_ID,
            holder,
            assetId,
            DataEncoding.encodeBridgeBurnData(STUCK_AMOUNT, l1Receiver, address(l2Token))
        );
        vm.prank(holder);
        IL2SharedBridgeLegacy(L2_ASSET_ROUTER_ADDR).withdraw(l1Receiver, address(l2Token), STUCK_AMOUNT);

        assertEq(l2Token.balanceOf(holder), 0);
        assertEq(l2Token.totalSupply(), 0);
    }

    /// @dev A token native to L2 is locked in the native token vault with `transferFrom`, so its withdrawal needs an
    /// `approve` first: one more priority transaction, which `WITHDRAWALS_ONLY` mode rejects unless the chain admin
    /// allows it.
    function test_forcedWithdrawalOfL2NativeTokenNeedsAllowance() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", TOKEN_DEFAULT_DECIMALS);
        l2NativeToken.mint(holder, STUCK_AMOUNT);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));
        bytes memory assetData = DataEncoding.encodeBridgeBurnData(STUCK_AMOUNT, l1Receiver, address(l2NativeToken));

        vm.prank(holder);
        vm.expectRevert("ERC20: insufficient allowance");
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(assetId, assetData);

        vm.prank(holder);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, STUCK_AMOUNT);
        vm.prank(holder);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(assetId, assetData);

        assertEq(l2NativeToken.balanceOf(holder), 0);
        assertEq(l2NativeToken.balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR), STUCK_AMOUNT);
    }
}
