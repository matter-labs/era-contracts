// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/libraries/Diamond.sol";
import "../../state-transition/chain-deps/facets/Getters.sol";

contract DiamondCutTestContract is GettersFacet {
    function diamondCut(Diamond.DiamondCutData memory _diamondCut) external {
        Diamond.diamondCut(_diamondCut);
    }
}
