// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {MAX_TOKEN_BALANCE} from "contracts/common/Config.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetHandler} from "contracts/bridge/interfaces/IL2AssetHandler.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    AssetIdNotRegistered,
    BaseTokenNativeToThisChain,
    RecoverToL1NotSupported,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";
import {SharedL2ContractL1Deployer} from "./_SharedL2ContractL1Deployer.sol";

contract L2AssetTrackerL1Test is Test, SharedL2ContractL1Deployer {
    function test_handleInitiateBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("NativeToken", "NTV", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 amount = 7;

        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(address(token));
        uint256 balanceBefore = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceBefore, MAX_TOKEN_BALANCE, "Native token should be initialized on registration");

        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        uint256 balanceAfter = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceAfter, balanceBefore - amount, "Native token chain balance should decrease after withdrawal");
    }

    function test_handleFinalizeBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyToken", "LGC", 18);
        address l1Token = makeAddr("legacy_l1_token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        uint256 amount = 11;

        // An unregistered foreign asset must be rejected by handleFinalizeBridgingOnL2.
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleFinalizeBridgingOnL2(L1_CHAIN_ID, assetId, amount, L1_CHAIN_ID, address(token));
    }

    function test_handleFinalizeBaseTokenBridgingOnL2() public {
        _checkFinalizeBaseTokenBridging(L2_BASE_TOKEN_HOLDER_ADDR);
    }

    function test_handleFinalizeBaseTokenBridgingOnL2_nativeVmCaller() public {
        _checkFinalizeBaseTokenBridging(address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
    }

    function _checkFinalizeBaseTokenBridging(address _caller) private {
        vm.clearMockedCalls();
        bytes32 baseTokenAssetId = L2AssetTracker(L2_ASSET_TRACKER_ADDR).BASE_TOKEN_ASSET_ID();
        uint256 l1ChainId = L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID();
        uint256 amount = 300;
        uint256 totalSupply = 1000;

        // A fresh tracker exercises first registration against the initialized vault.
        L2AssetTracker tracker = new L2AssetTracker();
        vm.prank(_caller);
        tracker.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, 0);
        assertFalse(tracker.isAssetRegistered(bytes32(0)));
        (, uint256 uninitializedDeposits) = tracker.interopInfo(bytes32(0));
        assertEq(uninitializedDeposits, 0);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tracker.initL2(l1ChainId, baseTokenAssetId);

        // Isolate VM-provided supply and settlement context absent from the L1 test environment.
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(totalSupply)
        );
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        assertFalse(tracker.isAssetRegistered(baseTokenAssetId));
        vm.prank(_caller);
        tracker.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        assertEq(tracker.chainBalance(block.chainid, baseTokenAssetId), 0);
        (uint256 withdrawals, uint256 deposits) = tracker.interopInfo(baseTokenAssetId);
        assertEq(withdrawals, 0);
        assertEq(deposits, amount);
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId));
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved);
        assertEq(savedAmount, totalSupply);

        vm.prank(_caller);
        tracker.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, 0);
        (, deposits) = tracker.interopInfo(baseTokenAssetId);
        assertEq(deposits, amount);
    }

    /// @notice A random address must not be able to call handleFinalizeBaseTokenBridgingOnL2.
    function test_handleFinalizeBaseTokenBridgingOnL2_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(1, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  assertRecoveryIsAccountingNeutral
    // ═══════════════════════════════════════════════════════════════════

    /// @notice An L2->L2 base-token recovery is accepted and mutates no accounting: the forward direction
    /// (`handleInitiateBaseTokenBridgingOnL2`) records nothing for an L2->L2 bridge-out of the
    /// never-native base token, so there is nothing to reverse.
    /// @dev Runs against the live initialized state (the tracker and NTV are initialized with the real
    /// base token asset id during environment genesis) — no mocks or storage writes. The environment-wide
    /// mocks are cleared first: the shared deployer mocks `NTV.originChainId(base)` to `block.chainid`
    /// for its chain-migration fixtures, which would shadow the NTV's real initialized state.
    function test_assertBaseTokenRecoveryIsAccountingNeutral_noAccountingToReverse() public {
        vm.clearMockedCalls();
        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        bytes32 liveBaseTokenAssetId = tracker.BASE_TOKEN_ASSET_ID();
        uint256 nonL1DestinationChainId = 505;
        uint256 amount = 300;

        uint256 withdrawalsBefore = _readTotalWithdrawalsToL1(liveBaseTokenAssetId);
        uint256 chainBalanceBefore = tracker.chainBalance(block.chainid, liveBaseTokenAssetId);

        L2_ASSET_TRACKER.assertBaseTokenRecoveryIsAccountingNeutral(nonL1DestinationChainId);

        assertEq(
            tracker.chainBalance(block.chainid, liveBaseTokenAssetId),
            chainBalanceBefore,
            "no chainBalance may be re-credited: the base token is never native, so none was decreased"
        );
        assertEq(
            _readTotalWithdrawalsToL1(liveBaseTokenAssetId),
            withdrawalsBefore,
            "totalWithdrawalsToL1 must not move for an L2->L2 recovery"
        );
    }

    /// @notice Recovering an L1-destined bridge-out is unreachable (the InteropCenter rejects L1-destined
    /// atomic bundles at send, and no other revert path exists) and must revert: `totalWithdrawalsToL1`
    /// is consumed once during the L1->GW migration and must stay append-only.
    function test_assertBaseTokenRecoveryIsAccountingNeutral_revertWhenToL1() public {
        uint256 liveL1ChainId = L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID();

        vm.expectRevert(RecoverToL1NotSupported.selector);
        L2_ASSET_TRACKER.assertBaseTokenRecoveryIsAccountingNeutral(liveL1ChainId);
    }

    /// @notice The same gate covers every other asset: an L1-destined bridge-out of an ERC20 can never
    /// legitimately be recovered on L2 either, and the vault asks the tracker before disbursing.
    function test_assertRecoveryIsAccountingNeutral_revertsForL1DestinationOfAnyAsset() public {
        uint256 liveL1ChainId = L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID();
        bytes32 erc20AssetId = DataEncoding.encodeNTVAssetId(block.chainid, makeAddr("someNativeToken"));

        vm.expectRevert(RecoverToL1NotSupported.selector);
        L2_ASSET_TRACKER.assertRecoveryIsAccountingNeutral(erc20AssetId, liveL1ChainId);

        // An L2 destination is fine: the vault re-credits `chainBalance` through the finalize hook.
        L2_ASSET_TRACKER.assertRecoveryIsAccountingNeutral(erc20AssetId, 505);
    }

    /// @notice The base token can never originate from this chain (`handleFinalizeBaseTokenBridgingOnL2`
    /// hard-codes non-native); the recovery hook asserts the invariant instead of silently re-crediting
    /// a chainBalance that was never decreased.
    /// @dev The impossible state is reached through the real initialization method rather than a storage
    /// write: `updateL2` (pranked as the upgrader) re-writes the base token's `originChainId` while the
    /// asset id itself stays frozen. Environment-wide mocks are cleared first (see
    /// `test_assertBaseTokenRecoveryIsAccountingNeutral_noAccountingToReverse`) so the revert provably comes from
    /// the NTV's real storage, not the deployer's `originChainId` mock.
    function test_assertBaseTokenRecoveryIsAccountingNeutral_revertWhenBaseTokenNativeToThisChain() public {
        vm.clearMockedCalls();
        L2NativeTokenVault ntv = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        uint256 liveL1ChainId = ntv.L1_CHAIN_ID();
        address liveOwner = ntv.owner();
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
        ntv.updateL2(liveL1ChainId, liveOwner, liveWethToken, bridgingData, metadata);

        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        L2_ASSET_TRACKER.assertBaseTokenRecoveryIsAccountingNeutral(505);
    }

    /// @notice The vault must consult the gate before disbursing a failed transfer, for a plain ERC20
    /// too — not only for the base token. Driven through the real `bridgeRecoverFailedTransfer` entry
    /// point as the asset router, so deleting the vault's `assertRecoveryIsAccountingNeutral` call
    /// fails this test rather than silently widening what can be recovered.
    /// @dev The upstream routers already reject L1-destined recoveries, which is why this is the only
    /// way to reach the vault's own check.
    function test_bridgeRecoverFailedTransfer_asksTheTrackerBeforeDisbursing() public {
        address depositor = makeAddr("depositor");
        uint256 amount = 5 ether;
        TestnetERC20Token token = new TestnetERC20Token("NativeToken", "NTV", 18);
        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(address(token));
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: depositor,
            _remoteReceiver: makeAddr("remoteReceiver"),
            _originToken: address(token),
            _amount: amount,
            _erc20Metadata: ""
        });

        // An L1-destined bridge-out is never revertable: `totalWithdrawalsToL1` is append-only.
        vm.prank(L2_ASSET_ROUTER_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        IL2AssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeRecoverFailedTransfer(L1_CHAIN_ID, assetId, mintData);

        // Control: nothing was disbursed and the tracker's accounting is untouched.
        assertEq(token.balanceOf(depositor), 0, "no tokens may be disbursed by a rejected recovery");
        assertEq(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId),
            MAX_TOKEN_BALANCE,
            "a rejected recovery must not re-credit chainBalance"
        );
    }
}
