// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title Shared functions that are not inherited to avoid double inheritance.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAssetRouterShared {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 and L2->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable;

    /// @notice Generates a calldata for calling the deposit finalization on the L2 native token contract.
    /// @param _sender The address of the deposit initiator.
    /// @param _assetId The deposited asset ID.
    /// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @return Returns calldata used on ZK chain.
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) external view returns (bytes memory);
}
