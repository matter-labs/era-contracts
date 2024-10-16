// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract GetVerifierParamsTest is GettersFacetTest {
    function test() public {
        VerifierParams memory expected = VerifierParams({
            recursionNodeLevelVkHash: keccak256("recursionNodeLevelVkHash"),
            recursionLeafLevelVkHash: keccak256("recursionLeafLevelVkHash"),
            recursionCircuitsSetVksHash: keccak256("recursionCircuitsSetVksHash")
        });
        gettersFacetWrapper.util_setVerifierParams(expected);

        VerifierParams memory received = gettersFacet.getVerifierParams();

        bytes32 expectedHash = keccak256(abi.encode(expected));
        bytes32 receivedHash = keccak256(abi.encode(received));
        assertEq(expectedHash, receivedHash, "Received Verifier Params is incorrect");
    }
}
