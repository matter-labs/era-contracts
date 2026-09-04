// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

/// @author Matter Labs
/// @notice This is used for fast debugging of the L2NTV by running it in L1 context, i.e. normal foundry.
contract L2NativeTokenVaultDev is L2NativeTokenVault {
    function deployBridgedStandardERC20(address _owner) external {
        _transferOwnership(_owner);

        address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());

        UpgradeableBeacon tokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);

        tokenBeacon.transferOwnership(owner());
        bridgedTokenBeacon = IBeacon(address(tokenBeacon));
        emit L2TokenBeaconUpdated(address(bridgedTokenBeacon), L2_TOKEN_PROXY_BYTECODE_HASH());
    }

    function test() external pure {
        // test
    }
}
