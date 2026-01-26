// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DummyL2AssetRouter {
    uint256 public l1ChainId;
    address public l1AssetRouter;
    address public legacyBridge;
    bytes32 public baseTokenAssetId;
    uint256 public eraChainId;

    constructor(
        uint256 _l1ChainId,
        address _l1AssetRouter,
        address _legacyBridge,
        bytes32 _baseTokenAssetId,
        uint256 _eraChainId
    ) {
        l1ChainId = _l1ChainId;
        l1AssetRouter = _l1AssetRouter;
        legacyBridge = _legacyBridge;
        baseTokenAssetId = _baseTokenAssetId;
        eraChainId = _eraChainId;
    }
}
