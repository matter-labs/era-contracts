// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehub, IInteropCenter, L1Nullifier} from "../bridge/L1Nullifier.sol";

contract L1NullifierDev is L1Nullifier {
    constructor(
        IBridgehub _bridgehub,
        IInteropCenter _interopCenter,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) L1Nullifier(_bridgehub, _interopCenter, _eraChainId, _eraDiamondProxy) {}

    function setL2LegacySharedBridge(uint256 _chainId, address _l2Bridge) external {
        __DEPRECATED_l2BridgeAddress[_chainId] = _l2Bridge;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
