// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L2SharedBridge} from "../bridge/L2SharedBridge.sol";
import {L2StandardERC20} from "../bridge/L2StandardERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @author Matter Labs
/// @notice The implementation of the shared bridge that allows setting legacy bridge. Must only be used in local testing environments.
contract DevL2SharedBridge is L2SharedBridge {
    constructor(uint256 _eraChainId) L2SharedBridge(_eraChainId) {}

    function initializeDevBridge(
        address _l1SharedBridge,
        address _l1Bridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner
    ) external reinitializer(2) {
        l1SharedBridge = _l1SharedBridge;

        address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
        l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
        l2TokenBeacon.transferOwnership(_aliasedOwner);

        // Unfortunately the `l1Bridge` is not an internal variable in the parent contract.
        // To keep the changes to the production code minimal, we'll just manually set the variable here.
        assembly {
            sstore(4, _l1Bridge)
        }
    }
}
