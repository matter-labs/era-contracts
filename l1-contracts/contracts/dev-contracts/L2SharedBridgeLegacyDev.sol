// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {BridgedStandardERC20} from "../bridge/BridgedStandardERC20.sol";

import {L2SharedBridgeLegacy} from "../bridge/L2SharedBridgeLegacy.sol";
import {InvalidCaller, ZeroAddress, EmptyBytes32, Unauthorized, AmountMustBeGreaterThanZero, DeployFailed} from "../common/L1ContractErrors.sol";

contract L2SharedBridgeLegacyDev is L2SharedBridgeLegacy {
    constructor() L2SharedBridgeLegacy() {}

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _legacyBridge The address of the L1 Bridge contract.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    function initializeDevBridge(
        address _legacyBridge,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner
    ) external reinitializer(2) {
        if (_l1SharedBridge == address(0)) {
            revert ZeroAddress();
        }

        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }

        if (_aliasedOwner == address(0)) {
            revert ZeroAddress();
        }

        l1SharedBridge = _l1SharedBridge;
        l1Bridge = _legacyBridge;

        // The following statement is true only in freshly deployed environments. However,
        // for those environments we do not need to deploy this contract at all.
        // This check is primarily for local testing purposes.
        if (l2TokenProxyBytecodeHash == bytes32(0) && address(l2TokenBeacon) == address(0)) {
            address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        }
    }
}
