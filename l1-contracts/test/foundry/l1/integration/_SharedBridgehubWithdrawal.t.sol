// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {BundleStatus, L2Message, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {InteropWithdrawalBundleEncoder} from "test-utils/InteropWithdrawalBundleEncoder.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {InsufficientChainBalance} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";

import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

/// @title SharedBridgehubWithdrawal
/// @notice Shared base for the Bridgehub invariant test harnesses that finalize base-token
/// withdrawals from L2 to L1 via the new asset-router API.
/// @dev De-duplicates the base-token withdrawal-finalization helpers that were previously copied
/// into both `BridgehubInvariantTests` and `BridgehubInvariantTests_1`. Both harnesses inherit this
/// base and share the withdrawal state (`currentUser`, `currentChainId`, `currentToken`,
/// `currentTokenAddress`, `tokenSumWithdrawal`) and the `useGivenToken` modifier, all of which are
/// assigned by other modifiers that remain in the subclasses (e.g. `useUser`, `useZKChain`).
abstract contract SharedBridgehubWithdrawal is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using LogFinder for Vm.Log[];

    address public currentUser;
    uint256 public currentChainId;
    address public currentTokenAddress = ETH_TOKEN_ADDRESS;
    TestnetERC20Token currentToken;

    // Total sum of withdrawn tokens, mapped by token address
    mapping(address token => uint256 deposited) public tokenSumWithdrawal;

    // use token specified by address, set contract variables
    modifier useGivenToken(address tokenAddress) {
        currentToken = TestnetERC20Token(tokenAddress);
        currentTokenAddress = tokenAddress;
        _;
    }

    /// @notice Finalizes an ERC20 base-token withdrawal from L2 to L1 via the new asset-router API.
    /// @dev The chain's base token is an ERC20 here, so the withdrawal decrements the chain's
    /// `chainBalance` for the base-token assetId and releases escrowed ERC20 to the recipient.
    function withdrawERC20Token(uint256 amountToWithdraw, address tokenAddress) internal useGivenToken(tokenAddress) {
        _finalizeBaseTokenWithdrawal(amountToWithdraw, false);
    }

    /// @notice Finalizes an ETH base-token withdrawal from L2 to L1 via the new asset-router API.
    /// @dev Same flow as `withdrawERC20Token` but the base token is native ETH, so ETH balances are
    /// asserted instead of ERC20 balances.
    function withdrawETHToken(uint256 amountToWithdraw, address tokenAddress) internal useGivenToken(tokenAddress) {
        _finalizeBaseTokenWithdrawal(amountToWithdraw, true);
    }

    /// @notice Drives a real `L1InteropHandler.executeBundle` for the current chain's base-token withdrawal
    /// and asserts the balance outcomes.
    /// @dev Replaces the removed legacy `L1AssetRouter.finalizeWithdrawal` flow. The withdrawal is
    /// reconstructed as the single-call interop bundle emitted by the L2 L2InteropCenter whose only call targets
    /// the L1 asset router's `finalizeDeposit` (the base-token assetId plus `encodeBridgeMintData` transfer
    /// data), and is finalized on L1 via `L1InteropHandler.executeBundle`.
    ///
    /// Mock justification: L2 batch commitments and merkle trees are unavailable in this L1-only
    /// integration environment, so the message-root inclusion proof that `L1InteropHandler` makes is mocked:
    ///   - `proveL2MessageInclusionShared` -> `true` (message accepted as included)
    /// It is mocked on the selector only (loose match) because the exact `L2Message`/leaf reconstructed inside
    /// the handler is an implementation detail we do not want to duplicate here.
    /// @param _amountToWithdraw The base-token amount to withdraw.
    /// @param _isEth Whether the chain's base token is native ETH (vs an ERC20).
    function _finalizeBaseTokenWithdrawal(uint256 _amountToWithdraw, bool _isEth) internal {
        // The withdrawal message carries the chain's base-token assetId. It is finalized via the
        // interop-bundle path, so the L2 sender is the L2 L2InteropCenter (the only sender the
        // nullifier accepts).
        bytes32 assetId = addresses.bridgehub.baseTokenAssetId(currentChainId);

        uint256 beforeBridgeBalance = _isEth
            ? address(addresses.l1NativeTokenVault).balance
            : currentToken.balanceOf(address(addresses.l1NativeTokenVault));
        uint256 beforeUserBalance = _isEth ? currentUser.balance : currentToken.balanceOf(currentUser);

        (bytes memory bundle, MessageInclusionProof memory proof) = _buildWithdrawal(assetId, _amountToWithdraw);
        _mockWithdrawalProof();

        if (beforeBridgeBalance < _amountToWithdraw) {
            // Not enough escrowed balance in the vault: the L1 NTV decreases the chain balance before releasing
            // funds (`_handleBridgeFromChain`), so the shortfall surfaces as `InsufficientChainBalance` — bubbled
            // up verbatim through the asset-router self-call and the interop handler.
            vm.expectRevert(
                abi.encodeWithSelector(InsufficientChainBalance.selector, currentChainId, assetId, _amountToWithdraw)
            );
            addresses.l1InteropHandler.executeBundle(bundle, proof);
            return;
        }
        tokenSumWithdrawal[currentTokenAddress] += _amountToWithdraw;

        vm.recordLogs();
        addresses.l1InteropHandler.executeBundle(bundle, proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (_isEth) {
            // Escrowed ETH left the vault and reached the recipient.
            assertEq(
                beforeBridgeBalance - address(addresses.l1NativeTokenVault).balance,
                _amountToWithdraw,
                "Vault ETH balance should decrease by withdrawal amount"
            );
            assertEq(currentUser.balance - beforeUserBalance, _amountToWithdraw, "User should receive withdrawn ETH");
        } else {
            // Escrowed ERC20 left the vault and reached the recipient.
            assertEq(
                beforeBridgeBalance - currentToken.balanceOf(address(addresses.l1NativeTokenVault)),
                _amountToWithdraw,
                "Vault token balance should decrease by withdrawal amount"
            );
            assertEq(
                currentToken.balanceOf(currentUser) - beforeUserBalance,
                _amountToWithdraw,
                "User should receive withdrawn tokens"
            );
        }

        // Bundle marked as fully executed (replay protection lives in the interop handler's bundle status).
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(currentChainId, bundle);
        assertTrue(
            addresses.l1InteropHandler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted,
            "Bundle should be marked as fully executed"
        );

        // Verify DepositFinalizedAssetRouter event emission.
        Vm.Log memory finalizedLog = logs.requireOne("DepositFinalizedAssetRouter(uint256,bytes32,bytes)");
        assertEq(uint256(finalizedLog.topics[1]), currentChainId, "DepositFinalizedAssetRouter chainId mismatch");
    }

    /// @notice Builds the withdrawal `bundle` and its `MessageInclusionProof` for a base-token withdrawal of
    /// `_amount` to `currentUser`, as consumed by `L1InteropHandler.executeBundle`.
    /// @dev Reconstructs the single-call interop bundle emitted by the L2 L2InteropCenter. For a base-token
    /// withdrawal, the original caller and origin token are empty and the metadata is empty (see
    /// `l2-withdrawal-helper.ts::finalizeWithdrawalOnL1`). The proof's message data is a placeholder because the
    /// handler substitutes it with the bundle while verifying inclusion (which is mocked here anyway).
    function _buildWithdrawal(
        bytes32 _assetId,
        uint256 _amount
    ) internal returns (bytes memory bundle, MessageInclusionProof memory proof) {
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: address(0),
            _remoteReceiver: currentUser,
            _originToken: address(0),
            _amount: _amount,
            _erc20Metadata: hex""
        });
        bundle = InteropWithdrawalBundleEncoder.encodeInteropWithdrawalBundle(
            currentChainId,
            address(addresses.sharedBridge),
            _assetId,
            transferData,
            _nextWithdrawalBundleSalt()
        );
        bytes32[] memory merkleProof = new bytes32[](1);
        proof = MessageInclusionProof({
            chainId: currentChainId,
            l1BatchNumber: uint256(uint160(makeAddr("l2BatchNumber"))),
            l2MessageIndex: uint256(uint160(makeAddr("l2MessageIndex"))),
            message: L2Message({
                txNumberInBatch: uint16(uint160(makeAddr("l2TxNumberInBatch"))),
                sender: L2_INTEROP_CENTER_ADDR,
                data: hex""
            }),
            proof: merkleProof
        });
    }

    /// @notice Mocks the message-root inclusion proof made by `L1InteropHandler` while proving bundle inclusion.
    /// @dev Mocked on selector only (loose match) so we do not have to reconstruct the exact `L2Message`/leaf.
    function _mockWithdrawalProof() internal {
        address messageRoot = address(addresses.l1InteropHandler.MESSAGE_ROOT());
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
    }
}
