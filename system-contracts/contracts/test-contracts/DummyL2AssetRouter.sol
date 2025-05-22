// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DummyL2AssetRouter {
    constructor(
        uint256 _l1ChainId,
        address _l1AssetRouter,
        address _aliasedL1Governance,
        bytes32 _baseTokenAssetId,
        uint256 _maxNumberOfZKChains
    ) {}
    uint256 public hello = 10;
    event Called(bytes data);

    function finalizeDeposit(uint256 _l2ChainId, bytes32 _assetId, bytes memory _data) public {
        hello = hello + 2;
        emit Called("0xdeadbeef");
    }
}
