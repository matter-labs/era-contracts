// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CalldataL1DAValidatorZKsyncOS} from "../../contracts/CalldataL1DAValidatorZKsyncOS.sol";
import {InvalidL2DAOutputHash} from "../../contracts/DAContractsErrors.sol";
import {L1DAValidatorOutput} from "../../contracts/IL1DAValidator.sol";

/// @dev Unit tests for `CalldataL1DAValidatorZKsyncOS.checkDA` — the ZKsync OS calldata DA validator. It is
/// content-blind: it forces the operator to publish, as calldata, exactly the payload committed by the batch
/// (`keccak256(operatorDAInput) == daCommitment`) and returns an all-empty output (state and blob content are
/// bound by the batch proof). No mock is needed: `checkDA` is `pure` and only hashes its input.
contract CalldataL1DAValidatorZKsyncOSTest is Test {
    CalldataL1DAValidatorZKsyncOS internal validator;

    function setUp() public {
        validator = new CalldataL1DAValidatorZKsyncOS();
    }

    /// @dev The operator publishes the exact payload and its keccak matches the commitment: the call succeeds
    /// and returns a zero state-diff hash plus empty blob arrays.
    function testCheckDAVerifiesAndReturnsEmptyOutput() public {
        bytes memory payload = abi.encodePacked("l2->l1 log region (logs + IMT leaves)");
        bytes32 daCommitment = keccak256(payload);

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, daCommitment, payload, 6);

        assertEq(output.stateDiffHash, bytes32(0), "stateDiffHash must be zero");
        assertEq(output.blobsLinearHashes.length, 0, "blobsLinearHashes must be empty");
        assertEq(output.blobsOpeningCommitments.length, 0, "blobsOpeningCommitments must be empty");
    }

    /// @dev `_maxBlobsSupported` is ignored: the output arrays are always empty. This is exactly what keeps
    /// the validator compatible with the ZKsync OS commit path, which reverts on non-zero blob arrays.
    function testCheckDAIgnoresMaxBlobsSupported() public {
        bytes memory payload = abi.encodePacked("payload");
        bytes32 daCommitment = keccak256(payload);

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(0, 0, daCommitment, payload, type(uint256).max);

        assertEq(output.blobsLinearHashes.length, 0, "arrays must be empty regardless of maxBlobsSupported");
        assertEq(output.blobsOpeningCommitments.length, 0);
    }

    /// @dev If the published bytes do not hash to the proven commitment, the operator did not publish the
    /// committed payload, so the call reverts with the (mismatching) commitment it was given.
    function testCheckDARevertsOnHashMismatch() public {
        bytes memory payload = abi.encodePacked("the real payload");
        bytes32 wrongCommitment = keccak256("a different payload");

        vm.expectRevert(abi.encodeWithSelector(InvalidL2DAOutputHash.selector, wrongCommitment));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, wrongCommitment, payload, 6);
    }
}
