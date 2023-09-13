// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/libraries/Diamond.sol";
import "../../proof-system/chain-deps/facets/ProofChainGetters.sol";

contract DiamondCutTest is ProofGettersFacet {
    function diamondCut(Diamond.DiamondCutData memory _diamondCut) external {
        Diamond.diamondCut(_diamondCut);
    }
}
