// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {INTEROP_POOL_CHAIN_ID} from "contracts/common/Config.sol";
import {ArrayLengthMismatch} from "contracts/common/L1ContractErrors.sol";
import {InteropNotEnabled} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {
    ChainBalanceAlreadyInInteropPool,
    ChainBalanceBackfillAlreadySet,
    ChainBalanceBackfillNotSet,
    ChainBalanceExceeded
} from "contracts/bridge/L1BridgeContractErrors.sol";

import {L1NativeTokenVaultTestBase} from "./L1NativeTokenVault.t.sol";

/// @dev Stands in for the bridged token the vault deploys for an asset native to another chain: these tests
/// are about the vault's per-chain accounting, not the bridged token implementation.
contract ChainBalanceBridgedToken is ERC20 {
    address public nativeTokenVault;
    address public originToken;

    constructor(address _nativeTokenVault, address _originToken) ERC20("Bridged", "BRD") {
        nativeTokenVault = _nativeTokenVault;
        originToken = _originToken;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function bridgeMint(address _to, uint256 _amount) external {
        require(msg.sender == nativeTokenVault, "Only NTV");
        _mint(_to, _amount);
    }

    function bridgeBurn(address _from, uint256 _amount) external {
        require(msg.sender == nativeTokenVault, "Only NTV");
        _burn(_from, _amount);
    }
}

/// @notice The per-chain balance cap, its backfill and the interop pool.
/// See {protocol-docs/interop-gating.md#per-chain-balance-cap} and {protocol-docs/interop-gating.md#interop-pool}.
contract L1NativeTokenVaultChainBalanceTest is L1NativeTokenVaultTestBase {
    /// @dev A chain the pooled escrow comes from: withdrawals from `chainId` beyond its own deposits are
    /// paid out of what was deposited here.
    uint256 internal constant OTHER_CHAIN_ID = SECOND_CHAIN_ID;

    /// @dev A chain that stays without interop while `chainId` and `OTHER_CHAIN_ID` have it.
    uint256 internal constant THIRD_CHAIN_ID = SECOND_CHAIN_ID + 1;

    /*//////////////////////////////////////////////////////////////
                                Backfill
    //////////////////////////////////////////////////////////////*/

    function test_setChainBalanceBackfill_sets() public {
        bytes32[] memory assetIds = new bytes32[](2);
        assetIds[0] = tokenAssetId;
        assetIds[1] = ETH_TOKEN_ASSET_ID;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 5;

        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceBackfilled(chainId, tokenAssetId, 100);
        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceBackfilled(chainId, ETH_TOKEN_ASSET_ID, 5);
        vm.prank(owner);
        nativeTokenVault.setChainBalanceBackfill(chainId, assetIds, amounts);

        _assertBackfill(chainId, tokenAssetId, 100, true);
        _assertBackfill(chainId, ETH_TOKEN_ASSET_ID, 5, true);
        _assertBackfill(OTHER_CHAIN_ID, tokenAssetId, 0, false);
    }

    function test_setChainBalanceBackfill_zeroIsSet() public {
        _assertBackfill(chainId, tokenAssetId, 0, false);

        _setChainBalanceBackfill(chainId, tokenAssetId, 0);

        _assertBackfill(chainId, tokenAssetId, 0, true);
    }

    function test_setChainBalanceBackfill_revertWhen_notOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        nativeTokenVault.setChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(100));
    }

    function test_setChainBalanceBackfill_revertWhen_lengthMismatch() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 2));
        nativeTokenVault.setChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), new uint256[](2));
    }

    function test_setChainBalanceBackfill_revertWhen_alreadySet() public {
        _setChainBalanceBackfill(chainId, tokenAssetId, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillAlreadySet.selector, chainId, tokenAssetId));
        nativeTokenVault.setChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(100));
        _assertBackfill(chainId, tokenAssetId, 0, true);

        // A batch with one asset already set reverts as a whole.
        bytes32[] memory assetIds = new bytes32[](2);
        assetIds[0] = ETH_TOKEN_ASSET_ID;
        assetIds[1] = tokenAssetId;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillAlreadySet.selector, chainId, tokenAssetId));
        nativeTokenVault.setChainBalanceBackfill(chainId, assetIds, new uint256[](2));
        _assertBackfill(chainId, ETH_TOKEN_ASSET_ID, 0, false);

        // Other assets and other chains stay settable.
        _setChainBalanceBackfill(chainId, ETH_TOKEN_ASSET_ID, 7);
        _assertBackfill(chainId, ETH_TOKEN_ASSET_ID, 7, true);
        _setChainBalanceBackfill(OTHER_CHAIN_ID, tokenAssetId, 9);
        _assertBackfill(OTHER_CHAIN_ID, tokenAssetId, 9, true);
    }

    /*//////////////////////////////////////////////////////////////
                    Tracking on chains without interop
    //////////////////////////////////////////////////////////////*/

    function test_deposit_tracksL1NativeAsset() public {
        _depositNativeTestToken(100);

        assertEq(nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId), 100);
        assertEq(nativeTokenVault.chainTotalDeposited(OTHER_CHAIN_ID, tokenAssetId), 0, "other chains untouched");
        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId), 0, "pool untouched");
    }

    function test_depositAndWithdrawal_trackAssetNativeToAThirdChain() public {
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(OTHER_CHAIN_ID);
        _depositBridgedToken(assetId, token, chainId, 50);
        assertEq(nativeTokenVault.chainTotalDeposited(chainId, assetId), 50, "deposit tracked");

        _withdraw(chainId, assetId, address(token), 30);
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, assetId), 30, "withdrawal tracked");
        assertEq(token.balanceOf(owner), 30, "withdrawal paid out");
    }

    function test_assetNativeToTheChain_untracked() public {
        // The chain mints its own asset, so withdrawals of it are not bounded by deposits.
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(chainId);
        _depositBridgedToken(assetId, token, chainId, 50);

        _withdraw(chainId, assetId, address(token), 80);

        assertEq(nativeTokenVault.chainTotalDeposited(chainId, assetId), 0, "deposit untracked");
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, assetId), 0, "withdrawal untracked");
        assertEq(token.balanceOf(owner), 80, "withdrawal paid out");
    }

    function test_withdrawal_tracked() public {
        _depositNativeTestToken(100);

        _withdraw(chainId, tokenAssetId, address(testToken), 60);

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 60);
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 0, "pool untouched");
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
    }

    /*//////////////////////////////////////////////////////////////
                    The cap on chains without interop
    //////////////////////////////////////////////////////////////*/

    function test_withdrawal_revertWhen_exceedingTheChainsDeposits() public {
        // The pooled escrow holds enough, but `chainId` only deposited 100 of it.
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _depositNativeTestToken(chainId, 100);

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 150,
            _totalWithdrawn: 150,
            _limit: 100
        });

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 0, "nothing recorded");
        assertEq(testToken.balanceOf(owner), 0, "nothing paid out");
    }

    function test_withdrawal_atTheCap() public {
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _depositNativeTestToken(chainId, 30);
        _setChainBalanceBackfill(chainId, tokenAssetId, 20);

        _withdraw(chainId, tokenAssetId, address(testToken), 50);
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 50, "withdrawn up to the cap");

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 1,
            _totalWithdrawn: 51,
            _limit: 50
        });
    }

    function test_withdrawal_succeedsAfterBackfill() public {
        // A withdrawal of a pre-upgrade balance: `chainId` made no deposit since the upgrade.
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 60,
            _totalWithdrawn: 60,
            _limit: 0
        });

        _setChainBalanceBackfill(chainId, tokenAssetId, 60);
        _withdraw(chainId, tokenAssetId, address(testToken), 60);

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 60);
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
    }

    function test_failedDepositClaim_countsAsWithdrawal() public {
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        bytes memory data = _depositNativeTestToken(chainId, 40);

        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, tokenAssetId, owner, data);

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 40, "claim recorded");
        assertEq(testToken.balanceOf(owner), 40, "claim paid out");
        // The claim used up the chain's deposits.
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 1,
            _totalWithdrawn: 41,
            _limit: 40
        });
    }

    function test_failedDepositClaim_revertWhen_exceedingTheCap() public {
        // A claim for a deposit `chainId` never received.
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        bytes memory data = DataEncoding.encodeBridgeBurnData(40, owner, address(testToken));

        vm.prank(address(assetRouter));
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceExceeded.selector, chainId, tokenAssetId, 40, 0));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, tokenAssetId, owner, data);
    }

    function test_withdrawal_backfillNearMaxDoesNotOverflow() public {
        _depositNativeTestToken(OTHER_CHAIN_ID, 10);
        _depositNativeTestToken(chainId, 10);
        _setChainBalanceBackfill(chainId, tokenAssetId, type(uint256).max);

        _withdraw(chainId, tokenAssetId, address(testToken), 20);

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 20);
    }

    /// @dev Random sequences of deposits, withdrawals and failed-deposit claims on a chain without interop:
    /// whatever succeeds keeps `chainTotalWithdrawn <= chainBalanceBackfill + chainTotalDeposited`, and
    /// whatever would break it reverts.
    function testFuzz_withdrawnNeverExceedsBackfillPlusDeposited(
        uint128 _backfill,
        uint128[8] calldata _amounts,
        uint8[8] calldata _actions
    ) public {
        // The pooled escrow from another chain, so `bridgedOut` never limits the withdrawals.
        _depositNativeTestToken(OTHER_CHAIN_ID, uint256(type(uint128).max) * 8);
        _setChainBalanceBackfill(chainId, tokenAssetId, _backfill);

        for (uint256 i = 0; i < _amounts.length; ++i) {
            uint256 amount = bound(_amounts[i], 1, type(uint128).max);
            uint256 action = _actions[i] % 3;
            if (action == 0) {
                _depositNativeTestToken(chainId, amount);
            } else {
                uint256 newWithdrawn = nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId) + amount;
                uint256 limit = uint256(_backfill) + nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId);
                bytes memory expectedRevert = newWithdrawn > limit
                    ? abi.encodeWithSelector(ChainBalanceExceeded.selector, chainId, tokenAssetId, newWithdrawn, limit)
                    : bytes("");
                _withdrawOrClaim(chainId, amount, action == 1, expectedRevert);
            }

            (uint256 backfill, ) = nativeTokenVault.chainBalanceBackfill(chainId, tokenAssetId);
            assertLe(
                nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId),
                backfill + nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId),
                "withdrawn <= backfill + deposited"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                            The interop pool
    //////////////////////////////////////////////////////////////*/

    function test_interopChain_depositAndWithdrawalGoToThePool() public {
        _mockInteropEnabled(chainId, true);

        _depositNativeTestToken(chainId, 100);
        _withdraw(chainId, tokenAssetId, address(testToken), 60);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId), 100, "deposit pooled");
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 60, "withdrawal pooled");
        assertEq(nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId), 0, "chain deposit untouched");
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 0, "chain withdrawal untouched");
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
    }

    function test_interopChains_shareThePool() public {
        // Interop moved the tokens deposited into `OTHER_CHAIN_ID` to `chainId`.
        _mockInteropEnabled(chainId, true);
        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _fillEscrowViaAChainWithoutInterop();

        _withdraw(chainId, tokenAssetId, address(testToken), 100);

        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 100);
        assertEq(testToken.balanceOf(owner), 100, "withdrawal paid out");
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 1,
            _totalWithdrawn: 101,
            _limit: 100
        });
    }

    function test_interopChain_revertWhen_usingTheBalanceOfAChainWithoutInterop() public {
        // The escrow holds enough, but only for `OTHER_CHAIN_ID`, which has no interop.
        _mockInteropEnabled(chainId, true);
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 60,
            _totalWithdrawn: 60,
            _limit: 0
        });

        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 0, "nothing recorded");
        assertEq(testToken.balanceOf(owner), 0, "nothing paid out");
    }

    function test_interopChain_balanceFromBeforeInteropNeedsTheMove() public {
        _depositNativeTestToken(chainId, 100);
        _mockInteropEnabled(chainId, true);

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 60,
            _totalWithdrawn: 60,
            _limit: 0
        });

        _setChainBalanceBackfill(chainId, tokenAssetId, 0);
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);
        _withdraw(chainId, tokenAssetId, address(testToken), 60);

        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 60);
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
    }

    function test_interopChain_failedDepositClaimCountsAgainstThePool() public {
        _mockInteropEnabled(chainId, true);
        bytes memory data = _depositNativeTestToken(chainId, 40);
        _fillEscrowViaAChainWithoutInterop();

        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, tokenAssetId, owner, data);

        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 40, "claim recorded");
        assertEq(testToken.balanceOf(owner), 40, "claim paid out");
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 1,
            _totalWithdrawn: 41,
            _limit: 40
        });
    }

    function test_interopChain_assetNativeToAChainWithInterop_untracked() public {
        // Interop moved tokens native to `OTHER_CHAIN_ID` to `chainId` without passing L1.
        _mockInteropEnabled(chainId, true);
        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(OTHER_CHAIN_ID);
        _depositBridgedToken(assetId, token, chainId, 20);

        _withdraw(chainId, assetId, address(token), 50);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, assetId), 0, "deposit untracked");
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, assetId), 0, "withdrawal untracked");
        assertEq(nativeTokenVault.chainTotalDeposited(chainId, assetId), 0, "chain deposit untouched");
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, assetId), 0, "chain withdrawal untouched");
        assertEq(token.balanceOf(owner), 50, "withdrawal paid out");
    }

    function test_interopChain_assetOriginGainsInterop_stopsTracking() public {
        _mockInteropEnabled(chainId, true);
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(OTHER_CHAIN_ID);
        _depositBridgedToken(assetId, token, chainId, 20);
        assertEq(
            nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, assetId),
            20,
            "tracked while the origin has no interop"
        );

        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        _depositBridgedToken(assetId, token, chainId, 5);
        _withdraw(chainId, assetId, address(token), 50);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, assetId), 20, "deposit untracked");
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, assetId), 0, "withdrawal untracked");
        assertEq(token.balanceOf(owner), 50, "withdrawal paid out");
    }

    function test_assetNativeToAChainWithInterop_cappedOnAChainWithoutInterop() public {
        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(OTHER_CHAIN_ID);
        _depositBridgedToken(assetId, token, chainId, 20);
        assertEq(nativeTokenVault.chainTotalDeposited(chainId, assetId), 20, "deposit tracked");

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: assetId,
            _token: address(token),
            _amount: 21,
            _totalWithdrawn: 21,
            _limit: 20
        });
        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, assetId), 0, "pool untouched");
    }

    function test_interopChain_assetNativeToAChainWithoutInterop_capped() public {
        _mockInteropEnabled(chainId, true);
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(OTHER_CHAIN_ID);

        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: assetId,
            _token: address(token),
            _amount: 50,
            _totalWithdrawn: 50,
            _limit: 0
        });
    }

    function test_interopChain_assetNativeToTheChain_untracked() public {
        _mockInteropEnabled(chainId, true);
        (bytes32 assetId, ChainBalanceBridgedToken token) = _registerBridgedToken(chainId);
        _depositBridgedToken(assetId, token, chainId, 50);

        _withdraw(chainId, assetId, address(token), 80);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, assetId), 0, "deposit untracked");
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, assetId), 0, "withdrawal untracked");
        assertEq(token.balanceOf(owner), 80, "withdrawal paid out");
    }

    function test_moveChainBalanceToInteropPool() public {
        _depositNativeTestToken(chainId, 100);
        _withdraw(chainId, tokenAssetId, address(testToken), 30);
        _setChainBalanceBackfill(chainId, tokenAssetId, 50);
        _mockInteropEnabled(chainId, true);
        // The pool already holds what `OTHER_CHAIN_ID` deposited.
        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        _depositNativeTestToken(OTHER_CHAIN_ID, 10);
        // The backfill stands for tokens escrowed before the deposits were recorded.
        _fillEscrowViaAChainWithoutInterop();

        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceMovedToInteropPool(chainId, tokenAssetId, 150, 30);
        // Anyone can move a balance.
        vm.prank(makeAddr("anyone"));
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);

        assertTrue(nativeTokenVault.chainBalanceInInteropPool(chainId, tokenAssetId), "moved");
        assertFalse(nativeTokenVault.chainBalanceInInteropPool(chainId, ETH_TOKEN_ASSET_ID), "other assets stay");
        assertEq(
            nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId),
            160,
            "deposited and backfill added"
        );
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 30, "withdrawn added");
        assertEq(nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId), 100, "chain deposit kept");
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 30, "chain withdrawal kept");

        _withdraw(chainId, tokenAssetId, address(testToken), 130);
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 1,
            _totalWithdrawn: 161,
            _limit: 160
        });
    }

    function test_moveChainBalanceToInteropPool_zeroBackfill() public {
        _depositNativeTestToken(chainId, 100);
        _setChainBalanceBackfill(chainId, tokenAssetId, 0);
        _mockInteropEnabled(chainId, true);

        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceMovedToInteropPool(chainId, tokenAssetId, 100, 0);
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId), 100);
        assertEq(nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId), 0);
    }

    function test_moveChainBalanceToInteropPool_revertWhen_interopNotEnabled() public {
        _setChainBalanceBackfill(chainId, tokenAssetId, 0);

        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, chainId));
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);
    }

    function test_moveChainBalanceToInteropPool_revertWhen_backfillNotSet() public {
        _depositNativeTestToken(chainId, 100);
        _mockInteropEnabled(chainId, true);

        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillNotSet.selector, chainId, tokenAssetId));
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);
    }

    function test_moveChainBalanceToInteropPool_revertWhen_alreadyMoved() public {
        _depositNativeTestToken(chainId, 100);
        _setChainBalanceBackfill(chainId, tokenAssetId, 0);
        _mockInteropEnabled(chainId, true);
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);

        vm.expectRevert(abi.encodeWithSelector(ChainBalanceAlreadyInInteropPool.selector, chainId, tokenAssetId));
        nativeTokenVault.moveChainBalanceToInteropPool(chainId, tokenAssetId);

        assertEq(nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId), 100, "moved once");
    }

    /// @dev Random sequences of deposits into chains with and without interop, and of withdrawals and
    /// failed-deposit claims from chains with interop: whatever succeeds keeps
    /// the pool's total withdrawn at most its total deposited, deposits into a chain without interop never
    /// reach the pool, and whatever would break the bound reverts.
    function testFuzz_poolWithdrawnNeverExceedsPoolDeposited(
        uint128[8] calldata _amounts,
        uint8[8] calldata _actions,
        bool[8] calldata _onOtherChain
    ) public {
        _mockInteropEnabled(chainId, true);
        _mockInteropEnabled(OTHER_CHAIN_ID, true);
        // Escrow for every withdrawal, so that only the pool bounds them.
        _depositNativeTestToken(THIRD_CHAIN_ID, uint256(type(uint128).max) * _amounts.length);

        for (uint256 i = 0; i < _amounts.length; ++i) {
            uint256 amount = bound(_amounts[i], 1, type(uint128).max);
            uint256 interopChainId = _onOtherChain[i] ? OTHER_CHAIN_ID : chainId;
            uint256 action = _actions[i] % 4;
            if (action == 0) {
                _depositNativeTestToken(interopChainId, amount);
            } else if (action == 1) {
                _depositNativeTestToken(THIRD_CHAIN_ID, amount);
            } else {
                uint256 newWithdrawn = nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId) +
                    amount;
                uint256 deposited = nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId);
                bytes memory expectedRevert = newWithdrawn > deposited
                    ? abi.encodeWithSelector(
                        ChainBalanceExceeded.selector,
                        interopChainId,
                        tokenAssetId,
                        newWithdrawn,
                        deposited
                    )
                    : bytes("");
                _withdrawOrClaim(interopChainId, amount, action == 2, expectedRevert);
            }

            assertLe(
                nativeTokenVault.chainTotalWithdrawn(INTEROP_POOL_CHAIN_ID, tokenAssetId),
                nativeTokenVault.chainTotalDeposited(INTEROP_POOL_CHAIN_ID, tokenAssetId),
                "pool withdrawn <= pool deposited"
            );
            assertEq(
                nativeTokenVault.chainTotalWithdrawn(THIRD_CHAIN_ID, tokenAssetId),
                0,
                "chain without interop untouched"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits into `THIRD_CHAIN_ID`, which has no interop, so that the escrow covers more than the
    /// interop pool and the pool, not the escrow, is what stops the withdrawals.
    function _fillEscrowViaAChainWithoutInterop() internal {
        _depositNativeTestToken(THIRD_CHAIN_ID, 1000);
    }

    function _assertBackfill(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _set) internal view {
        (uint256 amount, bool set) = nativeTokenVault.chainBalanceBackfill(_chainId, _assetId);
        assertEq(amount, _amount, "backfill amount");
        assertEq(set, _set, "backfill set");
    }

    /// @dev Registers a bridged token for an asset native to `_originChainId`.
    function _registerBridgedToken(
        uint256 _originChainId
    ) internal returns (bytes32 assetId, ChainBalanceBridgedToken token) {
        address originTokenAddress = makeAddr("originToken");
        token = new ChainBalanceBridgedToken(address(nativeTokenVault), originTokenAddress);
        assetId = DataEncoding.encodeNTVAssetId(_originChainId, originTokenAddress);
        nativeTokenVault.setNewTokenStorage(assetId, address(token), _originChainId);
    }

    function _depositBridgedToken(
        bytes32 _assetId,
        ChainBalanceBridgedToken _token,
        uint256 _chainId,
        uint256 _amount
    ) internal {
        _token.mint(owner, _amount);
        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeBurn(
            _chainId,
            0,
            _assetId,
            owner,
            DataEncoding.encodeBridgeBurnData(_amount, owner, address(_token))
        );
        assertEq(_token.balanceOf(owner), 0, "deposit burned");
    }

    function _mintData(address _token, uint256 _amount) internal view returns (bytes memory) {
        return
            DataEncoding.encodeBridgeMintData({
                _originalCaller: owner,
                _remoteReceiver: owner,
                _originToken: _token,
                _amount: _amount,
                _erc20Metadata: BridgeHelper.getERC20Getters(_token, block.chainid)
            });
    }

    function _withdraw(uint256 _chainId, bytes32 _assetId, address _token, uint256 _amount) internal {
        bytes memory mintData = _mintData(_token, _amount);
        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeMint(_chainId, _assetId, mintData);
    }

    /// @dev Takes `_amount` of the native test token out of `_chainId`, by a withdrawal if `_isWithdrawal`
    /// and by a failed-deposit claim otherwise, expecting `_expectedRevert` unless it is empty.
    function _withdrawOrClaim(
        uint256 _chainId,
        uint256 _amount,
        bool _isWithdrawal,
        bytes memory _expectedRevert
    ) internal {
        // Built before `expectRevert`, which would otherwise apply to the token getters the mint data reads.
        bytes memory data = _isWithdrawal
            ? _mintData(address(testToken), _amount)
            : DataEncoding.encodeBridgeBurnData(_amount, owner, address(testToken));
        if (_expectedRevert.length > 0) {
            vm.expectRevert(_expectedRevert);
        }
        vm.prank(address(assetRouter));
        if (_isWithdrawal) {
            nativeTokenVault.bridgeMint(_chainId, tokenAssetId, data);
        } else {
            nativeTokenVault.bridgeConfirmTransferResult(_chainId, TxStatus.Failure, tokenAssetId, owner, data);
        }
    }

    function _expectWithdrawalExceeds(
        uint256 _chainId,
        bytes32 _assetId,
        address _token,
        uint256 _amount,
        uint256 _totalWithdrawn,
        uint256 _limit
    ) internal {
        bytes memory mintData = _mintData(_token, _amount);
        vm.prank(address(assetRouter));
        vm.expectRevert(
            abi.encodeWithSelector(ChainBalanceExceeded.selector, _chainId, _assetId, _totalWithdrawn, _limit)
        );
        nativeTokenVault.bridgeMint(_chainId, _assetId, mintData);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
