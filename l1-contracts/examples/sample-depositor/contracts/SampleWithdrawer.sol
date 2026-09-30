// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_INTEROP_CENTER, L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

/// @title SampleWithdrawer
/// @notice Example L2 contract that receives bridged ERC20s (e.g. deposited by a `SampleDepositor`) and withdraws
/// them to arbitrary L1 recipients.
/// @dev A withdrawal is a non-atomic interop bundle sent to the L1 chain id. Its single indirect call targets the
/// L2AssetRouter, which burns the tokens from this contract; the bundle is executed on L1 by the L1InteropHandler
/// once its message-inclusion proof is available (`executeBundle`). L2 -> L1 bundles carry no interop fee, so no
/// base token is needed. The InteropCenter accepts each bundle salt only once per sender, hence the per-withdrawal
/// salt. See {protocol-docs/bridging.md#deposit-initiation-source-side}.
contract SampleWithdrawer is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The number of withdrawals sent so far. Doubles as the salt of the next withdrawal bundle.
    uint256 public withdrawalCount;

    /// @notice Emitted once a withdrawal bundle has been sent.
    /// @param l2Token The withdrawn token (its address on this chain).
    /// @param l1Recipient The L1 address that receives the tokens once the bundle is executed on L1.
    /// @param amount The withdrawn amount.
    /// @param bundleHash The hash of the interop bundle to execute on L1.
    event WithdrawalInitiated(address indexed l2Token, address indexed l1Recipient, uint256 amount, bytes32 bundleHash);

    /// @notice The token is unknown to the L2NativeTokenVault, so it cannot be bridged.
    error TokenNotRegistered(address l2Token);

    /// @notice Withdraws `_amount` of `_l2Token` held by this contract to `_l1Recipient` on L1.
    /// @param _l2Token The token on this chain. Every token bridged in from L1 is registered with the vault.
    /// @param _amount The amount to withdraw.
    /// @param _l1Recipient The L1 recipient.
    /// @return bundleHash The hash of the interop bundle to execute on L1.
    function withdraw(
        address _l2Token,
        uint256 _amount,
        address _l1Recipient
    ) external onlyOwner returns (bytes32 bundleHash) {
        bytes32 assetId = L2_NATIVE_TOKEN_VAULT.assetId(_l2Token);
        if (assetId == bytes32(0)) {
            revert TokenNotRegistered(_l2Token);
        }
        // The vault burns a bridged token directly, but pulls a chain-native one via allowance.
        IERC20(_l2Token).forceApprove(L2_NATIVE_TOKEN_VAULT_ADDR, _amount);

        InteropCallStarter[] memory calls = DataEncoding.encodeInteropWithdrawalCallStarters(
            assetId,
            DataEncoding.encodeBridgeBurnData(_amount, _l1Recipient, _l2Token)
        );
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (bytes32(++withdrawalCount)));

        bundleHash = L2_INTEROP_CENTER.sendBundle(
            InteroperableAddress.formatEvmV1(L2_INTEROP_CENTER.L1_CHAIN_ID()),
            calls,
            bundleAttributes
        );

        emit WithdrawalInitiated(_l2Token, _l1Recipient, _amount, bundleHash);
    }
}
