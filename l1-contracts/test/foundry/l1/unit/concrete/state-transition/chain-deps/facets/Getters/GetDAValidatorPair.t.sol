// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

contract GetDAValidatorPairTest is GettersFacetTest {
    function test_blobsZksyncOs() public {
        address expectedValidator = makeAddr("l1DAValidator");
        L2DACommitmentScheme expectedScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        gettersFacetWrapper.util_setL1DAValidator(expectedValidator);
        gettersFacetWrapper.util_setL2DACommitmentScheme(uint8(expectedScheme));

        (address receivedValidator, L2DACommitmentScheme receivedScheme) = gettersFacet.getDAValidatorPair();

        assertEq(expectedValidator, receivedValidator, "L1 DA Validator is incorrect");
        assertEq(uint8(expectedScheme), uint8(receivedScheme), "L2 DA Commitment Scheme is incorrect");
    }

    function test_pubdataKeccak256() public {
        address expectedValidator = makeAddr("l1DAValidator2");
        L2DACommitmentScheme expectedScheme = L2DACommitmentScheme.PUBDATA_KECCAK256;

        gettersFacetWrapper.util_setL1DAValidator(expectedValidator);
        gettersFacetWrapper.util_setL2DACommitmentScheme(uint8(expectedScheme));

        (address receivedValidator, L2DACommitmentScheme receivedScheme) = gettersFacet.getDAValidatorPair();

        assertEq(expectedValidator, receivedValidator, "L1 DA Validator is incorrect");
        assertEq(uint8(expectedScheme), uint8(receivedScheme), "L2 DA Commitment Scheme is incorrect");
    }

    function test_none() public {
        address expectedValidator = makeAddr("l1DAValidator3");
        L2DACommitmentScheme expectedScheme = L2DACommitmentScheme.NONE;

        gettersFacetWrapper.util_setL1DAValidator(expectedValidator);
        gettersFacetWrapper.util_setL2DACommitmentScheme(uint8(expectedScheme));

        (address receivedValidator, L2DACommitmentScheme receivedScheme) = gettersFacet.getDAValidatorPair();

        assertEq(expectedValidator, receivedValidator, "L1 DA Validator is incorrect");
        assertEq(uint8(expectedScheme), uint8(receivedScheme), "L2 DA Commitment Scheme is incorrect");
    }
}
