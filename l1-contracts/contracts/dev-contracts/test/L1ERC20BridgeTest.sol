// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1ERC20Bridge} from "../../bridge/L1ERC20Bridge.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";

/// @author Matter Labs
contract L1ERC20BridgeTest is L1ERC20Bridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor(
        IBridgehub _zkSync
    ) L1ERC20Bridge(IL1Nullifier(address(0)), IL1AssetRouter(address(0)), IL1NativeTokenVault(address(0)), 1) {}
}
