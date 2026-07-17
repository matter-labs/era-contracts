// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {
    AssetIdNotRegistered,
    BaseTokenNativeToThisChain,
    InsufficientChainBalance,
    RecoverToL1NotSupported,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

/// @notice Tests for the chain-local write-only bookkeeping: `bridgedOut` /
/// `preTrackingTotalSupply` / `interopInfo` on the L2NativeTokenVault and
/// `baseTokenInteropInfo` on the BaseTokenHolder.
abstract contract L2AssetBookkeepingTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function _ntv() internal pure returns (L2NativeTokenVault) {
        return L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    /// @dev Registers a fresh L2-native token in the vault and funds `_holder` with `_amount`.
    function _deployAndRegisterNativeToken(
        address _holder,
        uint256 _amount
    ) internal returns (TestnetERC20Token token, bytes32 assetId) {
        token = new TestnetERC20Token("NativeToken", "NTV", 18);
        assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(address(token));
        token.mint(_holder, _amount);
    }

    /// @dev Burns `_amount` of `_assetId` towards `_toChainId` through the real asset-router entry point.
    function _bridgeBurnErc20(uint256 _toChainId, bytes32 _assetId, address _originalCaller, uint256 _amount) internal {
        bytes memory data = abi.encode(_amount, makeAddr("remoteReceiver"), address(0));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeBurn(_toChainId, 0, _assetId, _originalCaller, data);
    }

    /// @dev Finalizes an inbound `_amount` of `_assetId` from `_fromChainId` through the real
    /// asset-router entry point (token must already be known to the vault).
    function _bridgeMintErc20(uint256 _fromChainId, bytes32 _assetId, address _receiver, uint256 _amount) internal {
        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: makeAddr("originalCaller"),
            _remoteReceiver: _receiver,
            _originToken: _ntv().tokenAddress(_assetId),
            _amount: _amount,
            _erc20Metadata: ""
        });
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeMint(_fromChainId, _assetId, data);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Token registration
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Registering a fresh native token initializes its bookkeeping: tracked, nothing
    /// bridged out yet and no supply snapshot (native tokens carry their accounting in `bridgedOut`).
    function test_registerToken_native_initializesBookkeeping() public {
        (, bytes32 assetId) = _deployAndRegisterNativeToken(makeAddr("caller"), 0);

        assertTrue(_ntv().isAssetTracked(assetId), "native token should be tracked on registration");
        assertEq(_ntv().bridgedOut(assetId), 0, "fresh native token has nothing bridged out");
        (bool isSaved, ) = _ntv().preTrackingTotalSupply(assetId);
        assertFalse(isSaved, "native tokens store no supply snapshot");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Outbound flows (bridgedOut / totalWithdrawalsToL1)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice An L1-destined burn of a native token increases both `bridgedOut` and the
    /// L1 withdrawal counter.
    function test_bridgeBurn_nativeTokenToL1_recordsBridgedOutAndWithdrawals() public {
        address caller = makeAddr("caller");
        uint256 amount = 7 ether;
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(caller, amount);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        uint256 withdrawalsBefore = _readTotalWithdrawalsToL1(assetId);

        _bridgeBurnErc20(L1_CHAIN_ID, assetId, caller, amount);

        assertEq(_ntv().bridgedOut(assetId), amount, "bridgedOut should increase by the burnt amount");
        assertEq(
            _readTotalWithdrawalsToL1(assetId) - withdrawalsBefore,
            amount,
            "totalWithdrawalsToL1 should increase for an L1-destined burn"
        );
        assertEq(token.balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR), amount, "escrow should match bridgedOut");
    }

    /// @notice A burn towards another L2 records `bridgedOut` but not the L1 withdrawal counter.
    function test_bridgeBurn_nativeTokenToL2_doesNotRecordWithdrawalsToL1() public {
        address caller = makeAddr("caller");
        uint256 amount = 3 ether;
        uint256 otherL2ChainId = 505;
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(caller, amount);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        uint256 withdrawalsBefore = _readTotalWithdrawalsToL1(assetId);

        _bridgeBurnErc20(otherL2ChainId, assetId, caller, amount);

        assertEq(_ntv().bridgedOut(assetId), amount, "bridgedOut should increase by the burnt amount");
        assertEq(
            _readTotalWithdrawalsToL1(assetId),
            withdrawalsBefore,
            "totalWithdrawalsToL1 must not move for an L2->L2 burn"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Inbound flows (bridgedOut decrease / totalSuccessfulDepositsFromL1)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice An inbound finalization of a native token from L1 decreases `bridgedOut` and bumps
    /// the L1 deposit counter; an inbound amount exceeding the outstanding bridged-out amount is
    /// blocked (only possible if bridged representations were forged upstream).
    function test_bridgeMint_nativeTokenFromL1_decreasesBridgedOutAndRecordsDeposits() public {
        address caller = makeAddr("caller");
        address receiver = makeAddr("receiver");
        uint256 amount = 5 ether;
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(caller, amount);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);
        _bridgeBurnErc20(L1_CHAIN_ID, assetId, caller, amount);
        assertEq(_ntv().bridgedOut(assetId), amount, "setup: full amount bridged out");

        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(assetId);

        _bridgeMintErc20(L1_CHAIN_ID, assetId, receiver, amount);

        assertEq(_ntv().bridgedOut(assetId), 0, "bridgedOut should return to zero after the round-trip");
        assertEq(
            _readTotalSuccessfulDepositsFromL1(assetId) - depositsBefore,
            amount,
            "totalSuccessfulDepositsFromL1 should increase for an L1-originated finalization"
        );
        assertEq(token.balanceOf(receiver), amount, "receiver should get the escrowed tokens");

        // Any further inbound amount exceeds the outstanding bridged-out amount and must revert.
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, 1); // donation so the escrow itself could cover it
        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: makeAddr("originalCaller"),
            _remoteReceiver: receiver,
            _originToken: address(token),
            _amount: 1,
            _erc20Metadata: ""
        });
        vm.expectRevert(abi.encodeWithSelector(InsufficientChainBalance.selector, L1_CHAIN_ID, assetId, 1));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeMint(L1_CHAIN_ID, assetId, data);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Legacy-token lazy tracking
    // ═══════════════════════════════════════════════════════════════════

    /// @notice A token registered in the vault before the bookkeeping existed (upgraded chains) is
    /// tracked lazily: a native token's `bridgedOut` is seeded with the vault's current escrow.
    function test_trackLegacyToken_native_seedsBridgedOutFromEscrow() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyNative", "LGN", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 escrowed = 42 ether;
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, escrowed);

        // Simulate the pre-existing vault registration of an upgraded chain (originChainId and
        // tokenAddress set, bookkeeping empty).
        _writeLegacyVaultRegistration(assetId, address(token), block.chainid);
        assertFalse(_ntv().isAssetTracked(assetId), "legacy token starts untracked");

        _ntv().trackLegacyToken(assetId);

        assertTrue(_ntv().isAssetTracked(assetId), "legacy token should be tracked");
        assertEq(_ntv().bridgedOut(assetId), escrowed, "bridgedOut should be seeded with the escrow");
        (bool isSaved, ) = _ntv().preTrackingTotalSupply(assetId);
        assertFalse(isSaved, "native tokens store no supply snapshot");

        // Tracking is idempotent: a second call (or a subsequent bridge op) must not re-seed.
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, 1 ether);
        _ntv().trackLegacyToken(assetId);
        assertEq(_ntv().bridgedOut(assetId), escrowed, "re-tracking must not re-seed bridgedOut");
    }

    /// @notice A legacy bridged token captures its pre-tracking total supply on first touch.
    function test_trackLegacyToken_bridged_capturesSupplySnapshot() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyBridged", "LGB", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, makeAddr("legacy_l1_token"));
        uint256 preTrackingSupply = 1000;
        token.mint(makeAddr("someHolder"), preTrackingSupply);

        _writeLegacyVaultRegistration(assetId, address(token), L1_CHAIN_ID);

        _ntv().trackLegacyToken(assetId);

        assertTrue(_ntv().isAssetTracked(assetId), "legacy token should be tracked");
        (bool isSaved, uint256 savedAmount) = _ntv().preTrackingTotalSupply(assetId);
        assertTrue(isSaved, "snapshot should be saved for bridged tokens");
        assertEq(savedAmount, preTrackingSupply, "snapshot should equal the pre-tracking totalSupply");
        assertEq(_ntv().bridgedOut(assetId), 0, "bridged tokens carry no bridgedOut accounting");
    }

    /// @notice A completely unknown asset cannot be tracked.
    function test_trackLegacyToken_revertUnknownAsset() public {
        bytes32 assetId = keccak256("unknown_asset");
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        _ntv().trackLegacyToken(assetId);
    }

    /// @notice The lazy tracking also fires inside the bridge hooks: the first outbound operation of
    /// a legacy native token seeds `bridgedOut` from the escrow BEFORE recording the operation.
    function test_bridgeBurn_legacyNativeToken_lazySeedHappensBeforeAccounting() public {
        address caller = makeAddr("caller");
        uint256 escrowed = 10 ether;
        uint256 amount = 2 ether;
        TestnetERC20Token token = new TestnetERC20Token("LegacyNative", "LGN", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, escrowed);
        token.mint(caller, amount);
        _writeLegacyVaultRegistration(assetId, address(token), block.chainid);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        _bridgeBurnErc20(L1_CHAIN_ID, assetId, caller, amount);

        assertEq(
            _ntv().bridgedOut(assetId),
            escrowed + amount,
            "bridgedOut = pre-existing escrow seed + newly burnt amount"
        );
        assertEq(
            token.balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR),
            escrowed + amount,
            "escrow should stay in lockstep with bridgedOut"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Base-token recovery invariants (BaseTokenHolder)
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Deploys the real BaseTokenHolder at its predeploy address (the shared environment etches
    /// a dummy) and funds it so recovery can pay out.
    function _etchRealBaseTokenHolder() internal returns (BaseTokenHolder holder) {
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, 1000 ether);
        holder = BaseTokenHolder(payable(L2_BASE_TOKEN_HOLDER_ADDR));
    }

    /// @notice An L2->L2 base-token recovery is accepted and mutates no accounting: the forward
    /// direction records nothing for an L2->L2 bridge-out of the never-native base token, so there
    /// is nothing to reverse.
    function test_recoverBaseToken_noAccountingToReverse() public {
        vm.clearMockedCalls();
        BaseTokenHolder holder = _etchRealBaseTokenHolder();
        address depositor = makeAddr("depositor");
        uint256 nonL1DestinationChainId = 505;
        uint256 amount = 300;

        (uint256 withdrawalsBefore, uint256 depositsBefore) = holder.baseTokenInteropInfo();

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        holder.recoverBaseToken(depositor, amount, nonL1DestinationChainId);

        (uint256 withdrawalsAfter, uint256 depositsAfter) = holder.baseTokenInteropInfo();
        assertEq(withdrawalsAfter, withdrawalsBefore, "totalWithdrawalsToL1 must not move for an L2->L2 recovery");
        assertEq(depositsAfter, depositsBefore, "totalSuccessfulDepositsFromL1 must not move on recovery");
        assertEq(depositor.balance, amount, "the escrowed value must be returned to the depositor");
    }

    /// @notice Recovering an L1-destined bridge-out is unreachable (the InteropCenter rejects
    /// L1-destined atomic bundles at send) and must revert: `totalWithdrawalsToL1` must stay
    /// append-only.
    function test_recoverBaseToken_revertWhenToL1() public {
        vm.clearMockedCalls();
        BaseTokenHolder holder = _etchRealBaseTokenHolder();
        uint256 liveL1ChainId = _ntv().L1_CHAIN_ID();

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        holder.recoverBaseToken(makeAddr("depositor"), 100, liveL1ChainId);
    }

    /// @notice The base token can never originate from this chain; the recovery asserts the
    /// invariant instead of silently skipping accounting that was never recorded.
    /// @dev The impossible state is reached through the real initialization method rather than a
    /// storage write: `updateL2` (pranked as the upgrader) re-writes the base token's
    /// `originChainId` while the asset id itself stays frozen.
    function test_recoverBaseToken_revertWhenBaseTokenNativeToThisChain() public {
        vm.clearMockedCalls();
        BaseTokenHolder holder = _etchRealBaseTokenHolder();
        L2NativeTokenVault ntv = _ntv();
        uint256 liveL1ChainId = ntv.L1_CHAIN_ID();
        address liveOwner = ntv.owner();
        bytes32 liveProxyBytecodeHash = ntv.L2_TOKEN_PROXY_BYTECODE_HASH();
        address liveWethToken = ntv.WETH_TOKEN();
        TokenBridgingData memory bridgingData = TokenBridgingData({
            assetId: ntv.BASE_TOKEN_ASSET_ID(),
            originChainId: block.chainid,
            originToken: ntv.BASE_TOKEN_ORIGIN_TOKEN()
        });
        TokenMetadata memory metadata = TokenMetadata({
            name: ntv.BASE_TOKEN_NAME(),
            symbol: ntv.BASE_TOKEN_SYMBOL(),
            decimals: ntv.BASE_TOKEN_DECIMALS()
        });

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        // solhint-disable-next-line func-named-parameters
        ntv.updateL2(liveL1ChainId, liveOwner, liveProxyBytecodeHash, liveWethToken, bridgingData, metadata);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        holder.recoverBaseToken(makeAddr("depositor"), 100, 505);
    }

    /// @notice Only the NativeTokenVault may trigger a base-token recovery.
    function test_recoverBaseToken_revertUnauthorized() public {
        BaseTokenHolder holder = _etchRealBaseTokenHolder();
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        holder.recoverBaseToken(makeAddr("depositor"), 100, 505);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Simulates the vault registration state of a token that predates the local bookkeeping
    /// (i.e. was registered on a chain upgraded in place): `tokenAddress`/`assetId`/`originChainId`
    /// set, `isAssetTracked` empty.
    function _writeLegacyVaultRegistration(bytes32 _assetId, address _tokenAddress, uint256 _originChainId) internal {
        stdstore
            .target(L2_NATIVE_TOKEN_VAULT_ADDR)
            .sig(INativeTokenVaultBase.tokenAddress.selector)
            .with_key(_assetId)
            .checked_write(_tokenAddress);
        stdstore
            .target(L2_NATIVE_TOKEN_VAULT_ADDR)
            .sig(INativeTokenVaultBase.assetId.selector)
            .with_key(_tokenAddress)
            .checked_write(_assetId);
        stdstore
            .target(L2_NATIVE_TOKEN_VAULT_ADDR)
            .sig(INativeTokenVaultBase.originChainId.selector)
            .with_key(_assetId)
            .checked_write(_originChainId);
    }
}
