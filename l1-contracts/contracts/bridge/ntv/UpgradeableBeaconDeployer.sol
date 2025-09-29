// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A contract that deploys the upgradeable beacon for the bridged standard ERC20 token.
/// @dev Besides separation of concerns, we need it as a separate contract to ensure that L2NativeTokenVaultZKOS
/// does not have to include BridgedStandardERC20 and UpgradeableBeacon and so can fit into the code size limit.
contract UpgradeableBeaconDeployer {
    function deployUpgradeableBeacon(address _owner) external returns (address) {
        address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());

        UpgradeableBeacon tokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);

        tokenBeacon.transferOwnership(_owner);
        return address(tokenBeacon);
    }
}
