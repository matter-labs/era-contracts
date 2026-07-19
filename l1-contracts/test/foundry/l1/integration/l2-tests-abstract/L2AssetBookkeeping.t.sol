// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

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
    BaseTokenNativeToThisChain,
    InsufficientChainBalance,
    RecoverToL1NotSupported,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

/// @notice Tests for the chain-local write-only bookkeeping: `bridgedOut` / `interopInfo` on the
/// L2NativeTokenVault and `baseTokenInteropInfo` on the BaseTokenHolder.
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
}
