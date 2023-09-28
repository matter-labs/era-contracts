// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../zksync/libraries/Diamond.sol";
import "../../zksync/facets/Base.sol";

contract DiamondUpgradeSecurityCouncil is Base {
    function upgrade(address _securityCouncil) external payable returns (bytes32) {
        s.upgrades.securityCouncil = _securityCouncil;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
