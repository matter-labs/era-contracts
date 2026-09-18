// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DummyAssetTracker {
    address public owner;

    constructor(
        uint256 _l1ChainId,
        address _bridgehub,
        address _assetRouter,
        address _nativeTokenVault,
        address _messageRoot
    ) {}
}
