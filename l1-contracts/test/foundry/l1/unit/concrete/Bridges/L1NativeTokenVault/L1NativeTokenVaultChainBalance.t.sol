// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {ArrayLengthMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    ChainBalanceBackfillAlreadyFinalized,
    ChainBalanceBackfillNotFinalized,
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

/// @notice The per-chain balance cap and its backfill. See {protocol-docs/interop-gating.md#per-chain-balance-cap}.
contract L1NativeTokenVaultChainBalanceTest is L1NativeTokenVaultTestBase {
    /// @dev A chain the pooled escrow comes from: withdrawals from `chainId` beyond its own deposits are
    /// paid out of what was deposited here.
    uint256 internal constant OTHER_CHAIN_ID = SECOND_CHAIN_ID;

    /*//////////////////////////////////////////////////////////////
                            Backfill admin
    //////////////////////////////////////////////////////////////*/

    function test_setChainBalanceBackfill_setsAndOverwrites() public {
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

        assertEq(nativeTokenVault.chainBalanceBackfill(chainId, tokenAssetId), 100);
        assertEq(nativeTokenVault.chainBalanceBackfill(chainId, ETH_TOKEN_ASSET_ID), 5);
        assertEq(nativeTokenVault.chainBalanceBackfill(OTHER_CHAIN_ID, tokenAssetId), 0, "other chains untouched");

        // Before the finalization a value is overwritten, so a wrong one can also be lowered.
        _setChainBalanceBackfill(chainId, tokenAssetId, 40);
        assertEq(nativeTokenVault.chainBalanceBackfill(chainId, tokenAssetId), 40, "overwritten");
        assertEq(nativeTokenVault.chainBalanceBackfill(chainId, ETH_TOKEN_ASSET_ID), 5, "other assets untouched");
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

    function test_setChainBalanceBackfill_revertWhen_finalized() public {
        _finalizeChainBalanceBackfill(chainId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillAlreadyFinalized.selector, chainId));
        nativeTokenVault.setChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(100));
    }

    function test_finalizeChainBalanceBackfill() public {
        vm.expectEmit(true, false, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceBackfillFinalized(chainId);
        _finalizeChainBalanceBackfill(chainId);

        assertTrue(nativeTokenVault.chainBalanceBackfillFinalized(chainId));
        assertFalse(nativeTokenVault.chainBalanceBackfillFinalized(OTHER_CHAIN_ID), "other chains untouched");
        // Other chains' backfill stays settable.
        _setChainBalanceBackfill(OTHER_CHAIN_ID, tokenAssetId, 7);
        assertEq(nativeTokenVault.chainBalanceBackfill(OTHER_CHAIN_ID, tokenAssetId), 7);
    }

    function test_finalizeChainBalanceBackfill_revertWhen_alreadyFinalized() public {
        _finalizeChainBalanceBackfill(chainId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillAlreadyFinalized.selector, chainId));
        nativeTokenVault.finalizeChainBalanceBackfill(chainId);
    }

    function test_finalizeChainBalanceBackfill_revertWhen_notOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        nativeTokenVault.finalizeChainBalanceBackfill(chainId);
    }

    function test_increaseChainBalanceBackfill_addsAfterFinalization() public {
        _setChainBalanceBackfill(chainId, tokenAssetId, 100);
        _finalizeChainBalanceBackfill(chainId);

        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.ChainBalanceBackfilled(chainId, tokenAssetId, 130);
        vm.prank(owner);
        nativeTokenVault.increaseChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(30));

        assertEq(nativeTokenVault.chainBalanceBackfill(chainId, tokenAssetId), 130, "added to the backfill");
    }

    function test_increaseChainBalanceBackfill_revertWhen_notFinalized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainBalanceBackfillNotFinalized.selector, chainId));
        nativeTokenVault.increaseChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(30));
    }

    function test_increaseChainBalanceBackfill_revertWhen_notOwner() public {
        _finalizeChainBalanceBackfill(chainId);

        vm.expectRevert("Ownable: caller is not the owner");
        nativeTokenVault.increaseChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(30));
    }

    function test_increaseChainBalanceBackfill_revertWhen_lengthMismatch() public {
        _finalizeChainBalanceBackfill(chainId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 0));
        nativeTokenVault.increaseChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), new uint256[](0));
    }

    /*//////////////////////////////////////////////////////////////
                                Tracking
    //////////////////////////////////////////////////////////////*/

    function test_deposit_tracksL1NativeAsset() public {
        _depositNativeTestToken(100);

        assertEq(nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId), 100);
        assertEq(nativeTokenVault.chainTotalDeposited(OTHER_CHAIN_ID, tokenAssetId), 0, "other chains untouched");
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
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
    }

    /*//////////////////////////////////////////////////////////////
                                The cap
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

    function test_withdrawal_succeedsAfterBackfillIncrease() public {
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _setChainBalanceBackfill(chainId, tokenAssetId, 60);
        _finalizeChainBalanceBackfill(chainId);
        _withdraw(chainId, tokenAssetId, address(testToken), 60);
        _expectWithdrawalExceeds({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _token: address(testToken),
            _amount: 10,
            _totalWithdrawn: 70,
            _limit: 60
        });

        vm.prank(owner);
        nativeTokenVault.increaseChainBalanceBackfill(chainId, _assetIdArray(tokenAssetId), _amountArray(10));
        _withdraw(chainId, tokenAssetId, address(testToken), 10);

        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 70);
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

    function test_withdrawal_notCappedWhenInteropEnabled() public {
        _depositNativeTestToken(OTHER_CHAIN_ID, 100);
        _mockInteropEnabled(chainId, true);

        _withdraw(chainId, tokenAssetId, address(testToken), 60);

        // Still tracked, even though it exceeds the chain's deposits and backfill.
        assertEq(nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId), 60);
        assertEq(testToken.balanceOf(owner), 60, "withdrawal paid out");
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
                bytes memory data = action == 1
                    ? _mintData(address(testToken), amount)
                    : DataEncoding.encodeBridgeBurnData(amount, owner, address(testToken));
                uint256 newWithdrawn = nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId) + amount;
                uint256 limit = uint256(_backfill) + nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId);
                if (newWithdrawn > limit) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            ChainBalanceExceeded.selector,
                            chainId,
                            tokenAssetId,
                            newWithdrawn,
                            limit
                        )
                    );
                }
                vm.prank(address(assetRouter));
                if (action == 1) {
                    nativeTokenVault.bridgeMint(chainId, tokenAssetId, data);
                } else {
                    nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, tokenAssetId, owner, data);
                }
            }

            assertLe(
                nativeTokenVault.chainTotalWithdrawn(chainId, tokenAssetId),
                nativeTokenVault.chainBalanceBackfill(chainId, tokenAssetId) +
                    nativeTokenVault.chainTotalDeposited(chainId, tokenAssetId),
                "withdrawn <= backfill + deposited"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    function _finalizeChainBalanceBackfill(uint256 _chainId) internal {
        vm.prank(owner);
        nativeTokenVault.finalizeChainBalanceBackfill(_chainId);
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
