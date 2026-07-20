// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CalldataL1DAValidatorZKsyncOS} from "../../contracts/CalldataL1DAValidatorZKsyncOS.sol";
import {InvalidL2DAOutputHash} from "../../contracts/DAContractsErrors.sol";
import {L1DAValidatorOutput} from "../../contracts/IL1DAValidator.sol";

/// @dev Covers `CalldataL1DAValidatorZKsyncOS.checkDA`: reverts unless `keccak256(operatorDAInput) == daCommitment`,
/// returns an all-empty output. No mocks needed: `checkDA` is `pure` and only hashes its input.
contract CalldataL1DAValidatorZKsyncOSTest is Test {
    CalldataL1DAValidatorZKsyncOS internal validator;

    function setUp() public {
        validator = new CalldataL1DAValidatorZKsyncOS();
    }

    function testCheckDAVerifiesAndReturnsEmptyOutput() public {
        bytes memory payload = abi.encodePacked("l2->l1 region: logs + message preimages");
        bytes32 daCommitment = keccak256(payload);

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, daCommitment, payload, 6);

        assertEq(output.stateDiffHash, bytes32(0), "stateDiffHash must be zero");
        assertEq(output.blobsLinearHashes.length, 0, "blobsLinearHashes must be empty");
        assertEq(output.blobsOpeningCommitments.length, 0, "blobsOpeningCommitments must be empty");
    }

    /// @dev Blob output arrays must stay empty regardless of `_maxBlobsSupported` — the ZKsync OS commit path
    /// reverts on non-zero blob arrays.
    function testCheckDAIgnoresMaxBlobsSupported() public {
        bytes memory payload = abi.encodePacked("payload");
        bytes32 daCommitment = keccak256(payload);

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(0, 0, daCommitment, payload, type(uint256).max);

        assertEq(output.blobsLinearHashes.length, 0, "arrays must be empty regardless of maxBlobsSupported");
        assertEq(output.blobsOpeningCommitments.length, 0);
    }

    function testCheckDARevertsOnHashMismatch() public {
        bytes memory payload = abi.encodePacked("the real payload");
        bytes32 wrongCommitment = keccak256("a different payload");

        vm.expectRevert(abi.encodeWithSelector(InvalidL2DAOutputHash.selector, wrongCommitment));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, wrongCommitment, payload, 6);
    }
}
