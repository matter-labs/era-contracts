// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-length-in-loops

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract that deterministically deploys a ProxyAdmin, while
/// ensuring that its owner is the aliased governance contract
contract L2ProxyAdminDeployer {
    address public immutable PROXY_ADMIN_ADDRESS;

    constructor(address _aliasedGovernance) {
        ProxyAdmin admin = new ProxyAdmin{salt: bytes32(0)}();
        admin.transferOwnership(_aliasedGovernance);

        PROXY_ADMIN_ADDRESS = address(admin);
    }
}
