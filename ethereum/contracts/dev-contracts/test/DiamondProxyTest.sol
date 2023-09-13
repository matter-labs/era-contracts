// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/libraries/Diamond.sol";
import "../../proof-system/chain-deps/facets/ProofChainBase.sol";

contract DiamondProxyTest is ProofChainBase {
    function setFreezability(bool _freeze) external returns (bytes32) {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();
        diamondStorage.isFrozen = _freeze;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
