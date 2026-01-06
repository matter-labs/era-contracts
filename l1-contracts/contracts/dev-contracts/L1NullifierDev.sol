// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1Bridgehub, L1Nullifier} from "../bridge/L1Nullifier.sol";
import {IMessageRoot} from "../core/message-root/IMessageRoot.sol";
import {IInteropCenter} from "../interop/IInteropCenter.sol";

contract L1NullifierDev is L1Nullifier {
    constructor(
        IL1Bridgehub _bridgehub,
        IMessageRoot _messageRoot,
        IInteropCenter _interopCenter,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) L1Nullifier(_bridgehub, _messageRoot, _eraChainId, _eraDiamondProxy) {}

    function setL2LegacySharedBridge(uint256 _chainId, address _l2Bridge) external {
        __DEPRECATED_l2BridgeAddress[_chainId] = _l2Bridge;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
