// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Test stub of the asset router's base-token deposit entry point.
/// @dev Mirrors `IAssetRouterShared.bridgehubDepositBaseToken` so fixtures wiring a shared
/// bridge address have a typed, current-signature no-op to point at.
contract DummyBaseTokenBridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable {}
}
