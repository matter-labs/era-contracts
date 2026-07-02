// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {FinalizeL1DepositParams, ProofData} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

    /// @notice Drives a real `L1Nullifier.finalizeDeposit` for the current chain's base-token withdrawal
    /// and asserts the balance outcomes.
    /// @dev Replaces the removed legacy `L1AssetRouter.finalizeWithdrawal` flow. The withdrawal message is
    /// reconstructed in the asset-router `finalizeDeposit` format (see
    /// `L1Nullifier._parseL2WithdrawalMessage`): the base-token assetId plus `encodeBridgeMintData`
    /// transfer data, sent by the L2 base-token system contract (the sender the nullifier validates for a
    /// base-token withdrawal in `_verifyWithdrawal`).
    ///
    /// Mock justification: L2 batch commitments and merkle trees are unavailable in this L1-only
    /// integration environment, so the two message-root proof calls that `_verifyWithdrawal` makes are
    /// mocked:
    ///   - `proveL2MessageInclusionShared` -> `true` (message accepted as included)
    ///   - `getProofData` -> a `ProofData` with `settlementLayerChainId = 0`, i.e. direct-L1 settlement,
    ///     which makes `L1AssetTracker._getWithdrawalChain` attribute the withdrawal to `currentChainId`.
    /// Both are mocked on the selector only (loose match) because the exact `L2Message`/leaf reconstructed
    /// inside the nullifier is an implementation detail we do not want to duplicate here.
    /// @param _amountToWithdraw The base-token amount to withdraw.
    /// @param _isEth Whether the chain's base token is native ETH (vs an ERC20).
    function _finalizeBaseTokenWithdrawal(uint256 _amountToWithdraw, bool _isEth) internal {
        // The base-token assetId is exactly what the nullifier compares the message assetId against; using
        // it guarantees the base-token branch (and its `L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR` sender check).
        bytes32 assetId = addresses.bridgehub.baseTokenAssetId(currentChainId);
        IAssetTrackerBase assetTracker = IAssetTrackerBase(address(addresses.l1NativeTokenVault.l1AssetTracker()));

        uint256 beforeChainBalance = assetTracker.chainBalance(currentChainId, assetId);
        uint256 beforeBridgeBalance = _isEth
            ? address(addresses.l1NativeTokenVault).balance
            : currentToken.balanceOf(address(addresses.l1NativeTokenVault));
        uint256 beforeUserBalance = _isEth ? currentUser.balance : currentToken.balanceOf(currentUser);

        FinalizeL1DepositParams memory params = _buildWithdrawalParams(assetId, _amountToWithdraw);
        _mockWithdrawalProof();

        if (beforeChainBalance < _amountToWithdraw) {
            // Not enough escrowed balance for this chain/asset -> the asset tracker reverts.
            vm.expectRevert();
            addresses.l1Nullifier.finalizeDeposit(params);
            return;
        }
        tokenSumWithdrawal[currentTokenAddress] += _amountToWithdraw;

        vm.recordLogs();
        addresses.l1Nullifier.finalizeDeposit(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Chain balance for the base-token asset decreased by the withdrawal amount.
        assertEq(
            beforeChainBalance - assetTracker.chainBalance(currentChainId, assetId),
            _amountToWithdraw,
            "Chain balance should decrease by withdrawal amount"
        );

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

        // Withdrawal marked as finalized (replay protection).
        assertTrue(
            addresses.l1Nullifier.isWithdrawalFinalized(currentChainId, params.l2BatchNumber, params.l2MessageIndex),
            "Withdrawal should be marked as finalized"
        );

        // Verify DepositFinalizedAssetRouter event emission.
        Vm.Log memory finalizedLog = logs.requireOne("DepositFinalizedAssetRouter(uint256,bytes32,bytes)");
        assertEq(uint256(finalizedLog.topics[1]), currentChainId, "DepositFinalizedAssetRouter chainId mismatch");
    }

    /// @notice Builds the `FinalizeL1DepositParams` for a base-token withdrawal of `_amount` to `currentUser`.
    /// @dev Reconstructs the asset-router `finalizeDeposit` withdrawal message. For a base-token withdrawal
    /// emitted by `L2BaseToken.withdraw`, the original caller and origin token are empty and the metadata is
    /// empty (see `l2-withdrawal-helper.ts::finalizeWithdrawalOnL1`).
    function _buildWithdrawalParams(
        bytes32 _assetId,
        uint256 _amount
    ) internal returns (FinalizeL1DepositParams memory params) {
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: address(0),
            _remoteReceiver: currentUser,
            _originToken: address(0),
            _amount: _amount,
            _erc20Metadata: hex""
        });
        bytes32[] memory merkleProof = new bytes32[](1);
        params = FinalizeL1DepositParams({
            chainId: currentChainId,
            l2BatchNumber: uint256(uint160(makeAddr("l2BatchNumber"))),
            l2MessageIndex: uint256(uint160(makeAddr("l2MessageIndex"))),
            l2Sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            l2TxNumberInBatch: uint16(uint160(makeAddr("l2TxNumberInBatch"))),
            message: DataEncoding.encodeAssetRouterFinalizeDepositData(currentChainId, _assetId, transferData),
            merkleProof: merkleProof
        });
    }

    /// @notice Mocks the two message-root proof calls made by `L1Nullifier._verifyWithdrawal`.
    /// @dev Mocked on selector only (loose match) so we do not have to reconstruct the exact `L2Message`/leaf.
    /// `getProofData` returns `settlementLayerChainId = 0` (direct L1 settlement) so the withdrawal is
    /// attributed to the source chain by `L1AssetTracker._getWithdrawalChain`.
    function _mockWithdrawalProof() internal {
        address messageRoot = address(addresses.l1Nullifier.MESSAGE_ROOT());
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        ProofData memory proofData;
        proofData.settlementLayerChainId = 0;
        vm.mockCall(messageRoot, abi.encodeWithSelector(IMessageRootBase.getProofData.selector), abi.encode(proofData));
    }
}
