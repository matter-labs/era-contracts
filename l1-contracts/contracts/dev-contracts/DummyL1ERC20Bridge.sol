// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1ERC20Bridge} from "../bridge/L1ERC20Bridge.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL1Nullifier} from "../bridge/interfaces/IL1Nullifier.sol";

contract DummyL1ERC20Bridge is L1ERC20Bridge {
    constructor(
        IL1Nullifier _l1Nullifier,
        IL1AssetRouter _l1SharedBridge,
        IL1NativeTokenVault _l1NativeTokenVault,
        uint256 _eraChainId
    ) L1ERC20Bridge(_l1Nullifier, _l1SharedBridge, _l1NativeTokenVault, _eraChainId) {}

    function setValues(address _l2SharedBridge, address _l2TokenBeacon, bytes32 _l2TokenProxyBytecodeHash) external {
        l2Bridge = _l2SharedBridge;
        l2TokenBeacon = _l2TokenBeacon;
        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
