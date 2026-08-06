// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {IL2AssetHandler} from "contracts/bridge/interfaces/IL2AssetHandler.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2AssetBookkeepingInfo} from "contracts/common/L2AssetBookkeeping.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";

import {
    AssetIdNotRegistered,
    AssetIdNotSupported,
    BaseTokenNativeToThisChain,
    InsufficientChainBalance,
    InvalidCaller,
    RecoverToL1NotSupported
} from "contracts/common/L1ContractErrors.sol";

contract L2NativeTokenVaultBookkeepingHarness is L2NativeTokenVault {
    function seedLegacyRegistration(bytes32 _assetId, address _tokenAddress, uint256 _originChainId) external {
        tokenAddress[_assetId] = _tokenAddress;
        assetId[_tokenAddress] = _assetId;
        originChainId[_assetId] = _originChainId;
    }

    /// @dev Stands in for `updateL2` on a fresh instance, so `trackBaseToken` can be exercised
    /// without the full init flow.
    function setBaseTokenAssetId(bytes32 _assetId) external {
        BASE_TOKEN_ASSET_ID = _assetId;
    }
}

/// @notice Tests for the chain-local bookkeeping that replaced the removed
/// L2AssetTracker: `bridgedOut` and the per-asset `assetBookkeeping` struct on the
/// L2NativeTokenVault, including the base-token flows reported by the BaseTokenHolder.
abstract contract L2AssetBookkeepingTest is Test, SharedL2ContractDeployer {
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
    /// bridged out yet, and the infinite-deposit pre-tracking baseline recorded.
    function test_registerToken_native_initializesBookkeeping() public {
        (, bytes32 assetId) = _deployAndRegisterNativeToken(makeAddr("caller"), 0);

        assertTrue(_ntv().isAssetTracked(assetId), "native token should be tracked on registration");
        assertEq(_ntv().bridgedOut(assetId), 0, "fresh native token has nothing bridged out");
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(savedAmount, type(uint256).max, "a fresh native token starts at the infinite-deposit baseline");
    }

    /// @notice The first deposit of a previously unseen bridged token registers and tracks it
    /// before minting.
    function test_bridgeMint_newBridgedToken_tracksBeforeFirstMint() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
        address originToken = makeAddr("newL1Token");
        address receiver = makeAddr("receiver");
        uint256 amount = 11 ether;
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, originToken);
        bytes memory metadata = DataEncoding.encodeTokenData(
            L1_CHAIN_ID,
            abi.encode("New Token"),
            abi.encode("NEW"),
            abi.encode(uint8(18))
        );
        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: makeAddr("depositor"),
            _remoteReceiver: receiver,
            _originToken: originToken,
            _amount: amount,
            _erc20Metadata: metadata
        });

        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeMint(L1_CHAIN_ID, assetId, data);

        address token = _ntv().tokenAddress(assetId);
        assertNotEq(token, address(0), "the bridged token should be deployed");
        assertTrue(_ntv().isAssetTracked(assetId), "the bridged token should be tracked during registration");
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(savedAmount, 0, "no flows predate a token registered by its first deposit");
        assertEq(IERC20(token).totalSupply(), amount, "the first deposit should mint the full amount");
        assertEq(IERC20(token).balanceOf(receiver), amount, "the receiver should receive the first deposit");
        assertEq(_readTotalSuccessfulDepositsFromL1(assetId), amount, "the first L1 deposit should be recorded");
    }

    /// @notice L1-native tokens use the L1 flow counters but never the L2-native `bridgedOut`
    /// accounting. This covers both the first-deposit deployment path and the return withdrawal.
    function test_l1NativeToken_roundTripRecordsFlowCountersOnly() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
        address originToken = makeAddr("l1Token");
        address receiver = makeAddr("receiver");
        uint256 amount = 11 ether;
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, originToken);
        bytes memory metadata = DataEncoding.encodeTokenData(
            L1_CHAIN_ID,
            abi.encode("L1 Token"),
            abi.encode("L1T"),
            abi.encode(uint8(18))
        );
        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: makeAddr("depositor"),
            _remoteReceiver: receiver,
            _originToken: originToken,
            _amount: amount,
            _erc20Metadata: metadata
        });

        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeMint(L1_CHAIN_ID, assetId, mintData);

        address bridgedToken = _ntv().tokenAddress(assetId);
        assertNotEq(bridgedToken, address(0), "the first deposit should deploy the bridged token");
        assertEq(IERC20(bridgedToken).balanceOf(receiver), amount, "the deposit should mint to the receiver");
        assertEq(_ntv().bridgedOut(assetId), 0, "L1-native tokens must not use L2 bridgedOut");
        assertEq(_readTotalSuccessfulDepositsFromL1(assetId), amount, "the L1 deposit must be recorded");
        assertEq(_readTotalWithdrawalsToL1(assetId), 0, "the deposit must not move withdrawals");

        _bridgeBurnErc20(L1_CHAIN_ID, assetId, receiver, amount);

        assertEq(IERC20(bridgedToken).balanceOf(receiver), 0, "the return withdrawal should burn the representation");
        assertEq(_ntv().bridgedOut(assetId), 0, "L1-native tokens must still not use L2 bridgedOut");
        assertEq(_readTotalSuccessfulDepositsFromL1(assetId), amount, "the deposit counter must stay append-only");
        assertEq(_readTotalWithdrawalsToL1(assetId), amount, "the return withdrawal must be recorded");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Outbound flows (bridgedOut / totalWithdrawalsToL1)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice An L1-destined burn of a native token increases both `bridgedOut` and the
    /// L1 withdrawal counter.
    function test_bridgeBurn_nativeTokenToL1_recordsBridgedOutAndWithdrawals() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
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
        _setCurrentSettlementLayer(L1_CHAIN_ID);
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

    /// @notice L1-addressed traffic while the chain settles elsewhere must not be attributed to L1.
    function test_bridgeBurn_nativeTokenToL1_whileSettlingOnGateway_doesNotRecordWithdrawal() public {
        _setCurrentSettlementLayer(GATEWAY_CHAIN_ID);
        address caller = makeAddr("caller");
        uint256 amount = 2 ether;
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(caller, amount);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        _bridgeBurnErc20(L1_CHAIN_ID, assetId, caller, amount);

        assertEq(_readTotalWithdrawalsToL1(assetId), 0, "gateway-settled flow must not be attributed to L1");
        assertEq(_ntv().bridgedOut(assetId), amount, "native-token safety accounting remains active");
    }

    /// @notice An L1-sourced finalization while settling on Gateway still releases a legitimately
    /// outstanding native token, but must not be counted as a direct L1 deposit.
    function test_bridgeMint_nativeTokenFromL1_whileSettlingOnGateway_doesNotRecordDeposit() public {
        address caller = makeAddr("caller");
        address receiver = makeAddr("receiver");
        uint256 amount = 2 ether;
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(caller, amount);
        vm.prank(caller);
        token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        _setCurrentSettlementLayer(L1_CHAIN_ID);
        _bridgeBurnErc20(L1_CHAIN_ID, assetId, caller, amount);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(assetId);

        _setCurrentSettlementLayer(GATEWAY_CHAIN_ID);
        _bridgeMintErc20(L1_CHAIN_ID, assetId, receiver, amount);

        assertEq(
            _readTotalSuccessfulDepositsFromL1(assetId),
            depositsBefore,
            "gateway-settled flow must not be attributed to L1"
        );
        assertEq(_ntv().bridgedOut(assetId), 0, "native-token safety accounting should complete the round-trip");
        assertEq(token.balanceOf(receiver), amount, "the legitimately outstanding tokens should be released");
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
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(
            savedAmount,
            type(uint256).max - escrowed,
            "the native baseline offsets the pre-tracking net inbound flow by MAX"
        );

        // Tracking is idempotent: a second call (or a subsequent bridge op) must not re-seed.
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, 1 ether);
        _ntv().trackLegacyToken(assetId);
        assertEq(_ntv().bridgedOut(assetId), escrowed, "re-tracking must not re-seed bridgedOut");
    }

    /// @notice A legacy bridged token records its pre-tracking net inbound flow (== its current
    /// totalSupply) and has no escrow to seed.
    function test_trackLegacyToken_bridged_capturesSupplySnapshot() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyBridged", "LGB", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, makeAddr("legacy_l1_token"));
        uint256 preTrackingSupply = 1000;
        token.mint(makeAddr("someHolder"), preTrackingSupply);

        _writeLegacyVaultRegistration(assetId, address(token), L1_CHAIN_ID);

        _ntv().trackLegacyToken(assetId);

        assertTrue(_ntv().isAssetTracked(assetId), "legacy token should be tracked");
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(savedAmount, preTrackingSupply, "the baseline equals the pre-tracking net inbound flow");
        assertEq(_ntv().bridgedOut(assetId), 0, "bridged tokens carry no bridgedOut accounting");
    }

    /// @notice A completely unknown asset cannot be tracked.
    function test_trackLegacyToken_revertUnknownAsset() public {
        bytes32 assetId = keccak256("unknown_asset");
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        _ntv().trackLegacyToken(assetId);
    }

    /// @notice The base token has no vault escrow to seed and is rejected outright; its baseline
    /// is recorded by `trackBaseToken` during the upgrade/genesis instead.
    function test_trackLegacyToken_revertBaseToken() public {
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, baseTokenAssetId));
        _ntv().trackLegacyToken(baseTokenAssetId);
    }

    /// @notice Genesis records the base token's baseline (the deployer mirrors
    /// `L2GenesisForceDeploymentsHelper`): tracked, saved, and zero — a fresh chain has no
    /// pre-tracking flows.
    function test_trackBaseToken_recordedDuringGenesisSetup() public {
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();
        assertTrue(_ntv().isAssetTracked(baseTokenAssetId), "the base token should be tracked from genesis");
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(baseTokenAssetId);
        // `isAssetTracked` (asserted above) doubles as the baseline-recorded marker.
        assertEq(snapshot.preTrackingTotalSupply, 0, "a fresh chain has no pre-tracking base-token flows");
    }

    /// @notice A repeated `trackBaseToken` (e.g. a later upgrade re-running the init helper) must
    /// not fold post-tracking supply into the baseline.
    function test_trackBaseToken_idempotent() public {
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();

        // Simulate post-genesis mints: the holder's balance drop raises the reported totalSupply.
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, L2_BASE_TOKEN_HOLDER_ADDR.balance - 5 ether);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        _ntv().trackBaseToken();

        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(baseTokenAssetId);
        assertEq(snapshot.preTrackingTotalSupply, 0, "a re-run must keep the originally recorded baseline");
    }

    /// @notice Only the upgrader may record the base token's baseline: from any later moment the
    /// current supply includes flows `assetBookkeeping` already records.
    function test_trackBaseToken_revertNotUpgrader() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidCaller.selector, address(this)));
        _ntv().trackBaseToken();
    }

    /// @notice An upgraded chain arrives with supply already in circulation; `trackBaseToken` must
    /// record exactly that supply, not zero. Runs on the real vault implementation (a fresh
    /// instance, since the deployer's genesis-like setup already tracked the base token at the
    /// canonical address).
    function test_trackBaseToken_recordsNonzeroPreUpgradeSupply() public {
        L2NativeTokenVaultBookkeepingHarness freshVault = new L2NativeTokenVaultBookkeepingHarness();
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();
        freshVault.setBaseTokenAssetId(baseTokenAssetId);

        // The holder's deficit against INITIAL is the circulating supply the dummy base token reports.
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE - 7 ether);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        freshVault.trackBaseToken();

        assertTrue(freshVault.isAssetTracked(baseTokenAssetId), "the base token must be tracked");
        assertEq(
            freshVault.assetBookkeeping(baseTokenAssetId).preTrackingTotalSupply,
            7 ether,
            "the pre-upgrade supply must become the recorded baseline"
        );
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
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(
            savedAmount,
            type(uint256).max - escrowed,
            "the baseline must be captured before the newly burnt amount enters escrow"
        );
    }

    /// @notice The lazy tracking also fires on the inbound hook: when a legacy native token's
    /// FIRST post-upgrade touch is an inbound finalization, `bridgedOut` is seeded from the escrow
    /// before being decremented, so a legitimately outstanding amount is released.
    function test_bridgeMint_legacyNativeToken_lazySeedAllowsOutstandingRelease() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
        address receiver = makeAddr("receiver");
        uint256 escrowed = 10 ether;
        uint256 amount = 4 ether;
        TestnetERC20Token token = new TestnetERC20Token("LegacyNative", "LGN", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        token.mint(L2_NATIVE_TOKEN_VAULT_ADDR, escrowed);
        _writeLegacyVaultRegistration(assetId, address(token), block.chainid);
        assertFalse(_ntv().isAssetTracked(assetId), "legacy token starts untracked");

        _bridgeMintErc20(L1_CHAIN_ID, assetId, receiver, amount);

        assertTrue(_ntv().isAssetTracked(assetId), "the inbound first touch should track the token");
        assertEq(token.balanceOf(receiver), amount, "the outstanding amount should be released from escrow");
        assertEq(_ntv().bridgedOut(assetId), escrowed - amount, "bridgedOut = seeded escrow - released amount");
        L2AssetBookkeepingInfo memory snapshot = _ntv().assetBookkeeping(assetId);
        uint256 savedAmount = snapshot.preTrackingTotalSupply;
        assertEq(
            savedAmount,
            type(uint256).max - escrowed,
            "the baseline must be captured from the pre-release escrow"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Failed-transfer recovery gating
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Recovery is gated for EVERY asset, not just the base token: an L1-destined
    /// bridge-out can never legitimately be recovered on L2 (`totalWithdrawalsToL1` is append-only),
    /// so the vault rejects it before touching any bookkeeping.
    function test_bridgeRecoverFailedTransfer_revertsForL1Destination() public {
        address depositor = makeAddr("depositor");
        (TestnetERC20Token token, bytes32 assetId) = _deployAndRegisterNativeToken(depositor, 5 ether);

        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: depositor,
            _remoteReceiver: makeAddr("remoteReceiver"),
            _originToken: address(token),
            _amount: 5 ether,
            _erc20Metadata: ""
        });
        vm.prank(L2_ASSET_ROUTER_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        IL2AssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeRecoverFailedTransfer(L1_CHAIN_ID, assetId, data);
    }

    /// @notice The chain-native check of the recovery gate must come from the REAL vault branch:
    /// a base token whose origin is this chain has no `bridgedOut` escrow to re-credit, so its
    /// recovery is rejected even for an L2 destination.
    function test_bridgeRecoverFailedTransfer_revertsWhenBaseTokenIsChainNative() public {
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();
        // Model the (unsupported) chain-native base token by overwriting its registered origin.
        _writeLegacyVaultRegistration(baseTokenAssetId, _ntv().tokenAddress(baseTokenAssetId), block.chainid);

        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: makeAddr("depositor"),
            _remoteReceiver: makeAddr("remoteReceiver"),
            _originToken: _ntv().tokenAddress(baseTokenAssetId),
            _amount: 1 ether,
            _erc20Metadata: ""
        });
        vm.prank(L2_ASSET_ROUTER_ADDR);
        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        IL2AssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeRecoverFailedTransfer(505, baseTokenAssetId, data);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Base-token flow recording (reported by BaseTokenHolder)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Only the BaseTokenHolder — which escrows the base token and therefore observes its
    /// contract-level bridge flows — may record base-token flows in the vault.
    function test_recordBaseTokenBridging_revertNotBaseTokenHolder() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidCaller.selector, address(this)));
        _ntv().recordBaseTokenBridgingToChain(L1_CHAIN_ID, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(InvalidCaller.selector, address(this)));
        _ntv().recordBaseTokenBridgingFromChain(L1_CHAIN_ID, 1 ether);
    }

    /// @notice L1-attributable base-token flows land in `assetBookkeeping[BASE_TOKEN_ASSET_ID]`, the same
    /// bookkeeping used for every other asset.
    function test_recordBaseTokenBridging_recordsUnderBaseTokenAssetId() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingToChain(L1_CHAIN_ID, 3 ether);
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingFromChain(L1_CHAIN_ID, 2 ether);

        assertEq(_readTotalWithdrawalsToL1(baseTokenAssetId), 3 ether, "L1 withdrawal should be recorded");
        assertEq(_readTotalSuccessfulDepositsFromL1(baseTokenAssetId), 2 ether, "L1 deposit should be recorded");
    }

    /// @notice Base-token flows to or from other L2s must not be attributed to L1.
    function test_recordBaseTokenBridging_l2Flows_notAttributedToL1() public {
        _setCurrentSettlementLayer(L1_CHAIN_ID);
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();
        uint256 otherL2ChainId = 505;

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingToChain(otherL2ChainId, 3 ether);
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingFromChain(otherL2ChainId, 2 ether);

        assertEq(_readTotalWithdrawalsToL1(baseTokenAssetId), 0, "L2-destined flow must not be attributed to L1");
        assertEq(
            _readTotalSuccessfulDepositsFromL1(baseTokenAssetId),
            0,
            "L2-sourced flow must not be attributed to L1"
        );
    }

    /// @notice L1-addressed base-token traffic while the chain settles elsewhere must not be
    /// attributed to L1.
    function test_recordBaseTokenBridging_gatewaySettlement_notAttributedToL1() public {
        _setCurrentSettlementLayer(GATEWAY_CHAIN_ID);
        bytes32 baseTokenAssetId = _ntv().BASE_TOKEN_ASSET_ID();

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingToChain(L1_CHAIN_ID, 3 ether);
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        _ntv().recordBaseTokenBridgingFromChain(L1_CHAIN_ID, 2 ether);

        assertEq(_readTotalWithdrawalsToL1(baseTokenAssetId), 0, "gateway-settled flow must not be attributed to L1");
        assertEq(
            _readTotalSuccessfulDepositsFromL1(baseTokenAssetId),
            0,
            "gateway-settled flow must not be attributed to L1"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Simulates the vault registration state of a token that predates the local bookkeeping
    /// (i.e. was registered on a chain upgraded in place): `tokenAddress`/`assetId`/`originChainId`
    /// set, `isAssetTracked` empty.
    function _writeLegacyVaultRegistration(bytes32 _assetId, address _tokenAddress, uint256 _originChainId) internal {
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(new L2NativeTokenVaultBookkeepingHarness()).code);
        L2NativeTokenVaultBookkeepingHarness(L2_NATIVE_TOKEN_VAULT_ADDR).seedLegacyRegistration(
            _assetId,
            _tokenAddress,
            _originChainId
        );
    }

    function _setCurrentSettlementLayer(uint256 _chainId) internal {
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(_chainId)
        );
    }
}
