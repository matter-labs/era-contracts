// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ConstructorsNotSupported, Unauthorized} from "../common/L1ContractErrors.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

contract SystemContractProxyAdmin is ProxyAdmin {
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice The constructor is never expected to be actually activated.
    constructor() {
        revert ConstructorsNotSupported();
    }

    /// @notice Initializer function to set the owner of the ProxyAdmin.
    function forceSetOwner(address _owner) external onlyUpgrader {
        _transferOwnership(_owner);
    }
}
