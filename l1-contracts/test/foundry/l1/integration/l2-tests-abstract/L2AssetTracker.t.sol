// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, console, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    L2_ASSET_TRACKER,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_CHAIN_ASSET_HANDLER,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_MESSAGE_ROOT,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {MAX_TOKEN_BALANCE} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {
    AssetAlreadyRegistered,
    AssetIdNotRegistered,
    BaseTokenNativeToThisChain
} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2UtilsBase} from "../l2-tests-in-l1-context/L2UtilsBase.sol";

import {
    Unauthorized,
    BaseTokenPreV31TotalSupplyNotSet,
    RecoverToL1NotSupported
} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

import {LogFinder} from "../utils/LogFinder.sol";

abstract contract L2AssetTrackerTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

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
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;
        uint256 mockedTotalSupply = 1000;

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);

        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(uint256(0));

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // totalSupply mock is needed for the foreign-token supply snapshot taken on first registration.
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(mockedTotalSupply)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertFalse(tracker.isAssetRegistered(baseTokenAssetId), "Asset should not be registered before call");

        // Call as BaseTokenHolder (onlyBaseTokenHolderOrL2BaseToken modifier).
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // The base token's origin is L1, so the block.chainid branch is not taken and the balance stays 0.
        assertEq(
            tracker.chainBalance(block.chainid, baseTokenAssetId),
            0,
            "Chain balance should remain 0 for foreign tokens"
        );

        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");

        // First contact triggers _registerLegacyTokenIfNeeded: registration + supply snapshot set.
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId), "Asset should be registered after call");
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(savedAmount, mockedTotalSupply, "totalPreV31TotalSupply.amount should equal mocked totalSupply");
    }

    /// @notice On Era, L2BaseTokenEra.mint() calls handleFinalizeBaseTokenBridgingOnL2 directly
    /// (msg.sender = L2_BASE_TOKEN_SYSTEM_CONTRACT). This must be allowed by access control.
    function test_handleFinalizeBaseTokenBridgingOnL2_calledByL2BaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;
        uint256 mockedTotalSupply = 1000;

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(mockedTotalSupply)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        uint256 chainBalanceBefore = tracker.chainBalance(block.chainid, baseTokenAssetId);
        assertFalse(tracker.isAssetRegistered(baseTokenAssetId), "Asset should not be registered before call");

        // Call as L2BaseToken (the Era flow: L2BaseTokenEra.mint() → asset tracker).
        vm.prank(address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // The base token's origin is L1, so the block.chainid branch is not taken; the balance is unchanged.
        assertEq(
            tracker.chainBalance(block.chainid, baseTokenAssetId),
            chainBalanceBefore,
            "Chain balance should remain unchanged for foreign-origin base token"
        );

        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");

        // First contact triggers _registerLegacyTokenIfNeeded: registration + supply snapshot set.
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId), "Asset should be registered after call");
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(savedAmount, mockedTotalSupply, "totalPreV31TotalSupply.amount should equal mocked totalSupply");
    }

    /// @notice A random address must not be able to call handleFinalizeBaseTokenBridgingOnL2.
    function test_handleFinalizeBaseTokenBridgingOnL2_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(1, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  handleRecoverBaseTokenBridgingOnL2
    // ═══════════════════════════════════════════════════════════════════

    /// @notice An L2->L2 base-token recovery is accepted and mutates no accounting: the forward direction
    /// (`handleInitiateBaseTokenBridgingOnL2`) records nothing for an L2->L2 bridge-out of the
    /// never-native base token, so there is nothing to reverse.
    /// @dev Runs against the live initialized state (the tracker and NTV are initialized with the real
    /// base token asset id during environment genesis) — no mocks or storage writes. The environment-wide
    /// mocks are cleared first: the shared deployer mocks `NTV.originChainId(base)` to `block.chainid`
    /// for its chain-migration fixtures, which would shadow the NTV's real initialized state.
    function test_handleRecoverBaseTokenBridgingOnL2_noAccountingToReverse() public {
        vm.clearMockedCalls();
        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        bytes32 liveBaseTokenAssetId = tracker.BASE_TOKEN_ASSET_ID();
        uint256 nonL1DestinationChainId = 505;
        uint256 amount = 300;

        uint256 withdrawalsBefore = _readTotalWithdrawalsToL1(liveBaseTokenAssetId);
        uint256 chainBalanceBefore = tracker.chainBalance(block.chainid, liveBaseTokenAssetId);

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleRecoverBaseTokenBridgingOnL2(nonL1DestinationChainId, amount);

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
    function test_handleRecoverBaseTokenBridgingOnL2_revertWhenToL1() public {
        uint256 liveL1ChainId = L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID();

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        L2_ASSET_TRACKER.handleRecoverBaseTokenBridgingOnL2(liveL1ChainId, 100);
    }

    /// @notice The base token can never originate from this chain (`handleFinalizeBaseTokenBridgingOnL2`
    /// hard-codes non-native); the recovery hook asserts the invariant instead of silently re-crediting
    /// a chainBalance that was never decreased.
    /// @dev The impossible state is reached through the real initialization method rather than a storage
    /// write: `updateL2` (pranked as the upgrader) re-writes the base token's `originChainId` while the
    /// asset id itself stays frozen. Environment-wide mocks are cleared first (see
    /// `test_handleRecoverBaseTokenBridgingOnL2_noAccountingToReverse`) so the revert provably comes from
    /// the NTV's real storage, not the deployer's `originChainId` mock.
    function test_handleRecoverBaseTokenBridgingOnL2_revertWhenBaseTokenNativeToThisChain() public {
        vm.clearMockedCalls();
        L2NativeTokenVault ntv = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
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

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        L2_ASSET_TRACKER.handleRecoverBaseTokenBridgingOnL2(505, 100);
    }

    /// @notice Only the BaseTokenHolder may report a base-token recovery.
    function test_handleRecoverBaseTokenBridgingOnL2_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.handleRecoverBaseTokenBridgingOnL2(505, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  registerBaseTokenDuringUpgrade
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies that registerBaseTokenDuringUpgrade registers the base token correctly.
    function test_registerBaseTokenDuringUpgrade_registersBaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        assertFalse(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should not be registered before call"
        );

        vm.expectEmit(true, false, false, false, L2_ASSET_TRACKER_ADDR);
        emit IL2AssetTracker.BaseTokenRegisteredDuringUpgrade(baseTokenAssetId);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();

        assertTrue(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should be registered after call"
        );

        (bool isSaved, uint256 amount) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(amount, 0, "totalPreV31TotalSupply.amount should be 0");
    }

    /// @notice Verifies that registerBaseTokenDuringUpgrade reverts if already registered.
    function test_registerBaseTokenDuringUpgrade_revertIfAlreadyRegistered() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("isAssetRegistered(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(true);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AssetAlreadyRegistered.selector, baseTokenAssetId));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    /// @notice Verifies that only the ComplexUpgrader can call registerBaseTokenDuringUpgrade.
    function test_registerBaseTokenDuringUpgrade_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    function test_handleFinalizeBaseTokenBridgingOnL2_succeedsWhileBackfillPending() public {
        bytes32 baseTokenAssetId = keccak256("zkos_base_token_pending_backfill");
        uint256 l1ChainId = 1;

        // Use the real ZKsync OS base token: its `totalSupply()` reverts while the pre-V31
        // supply has not been backfilled, so no mock is needed for the behaviour under test.
        vm.etch(address(L2_BASE_TOKEN_SYSTEM_CONTRACT), address(new L2BaseTokenZKOS()).code);

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("needBaseTokenTotalSupplyBackfill()").checked_write(true);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // Precondition of the regression: while the backfill is pending, the real base token's `totalSupply()`
        // (the exact call `_needToForceSetAssetMigrationOnL2` makes) reverts with this error.
        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        IERC20(address(L2_BASE_TOKEN_SYSTEM_CONTRACT)).totalSupply();

        // Register the base token exactly as the V31 upgrade does for an existing chain.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();

        // Settle on L1 so the deposit is accounted (same mock the sibling base-token tests use).
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);

        // The asset migration number is 0 (never set), which is exactly the path that reached the
        // reverting `totalSupply()` read before the fix; the finalization must now succeed.
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, 300);

        assertEq(
            _readTotalSuccessfulDepositsFromL1(baseTokenAssetId) - depositsBefore,
            300,
            "base-token deposit should be recorded while the supply is pending backfill"
        );
    }
}
