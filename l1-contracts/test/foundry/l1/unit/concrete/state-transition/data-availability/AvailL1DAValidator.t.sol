// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {AvailL1DAValidator} from "contracts/state-transition/data-availability/da-layers/avail/AvailL1DAValidator.sol";
import {DummyAvailBridge} from "contracts/state-transition/data-availability/da-layers/avail/DummyAvailBridge.sol";
import {IAvailBridge} from "contracts/state-transition/data-availability/da-layers/avail/IAvailBridge.sol";
import {
    InvalidAttestationProof,
    InvalidValidatorOutputHash
} from "contracts/state-transition/data-availability/DAErrors.sol";

contract AvailL1DAValidatorTest is Test {
    DummyAvailBridge internal bridge;
    AvailL1DAValidator internal validator;

    bytes32 internal constant STATE_DIFF_HASH = keccak256("stateDiffHash");

    function setUp() public {
        bridge = new DummyAvailBridge();
        validator = new AvailL1DAValidator(IAvailBridge(address(bridge)));
    }

    function _proofInput() internal pure returns (IAvailBridge.MerkleProofInput memory input) {
        input.dataRootProof = new bytes32[](1);
        input.dataRootProof[0] = keccak256("dataRootProof");
        input.leafProof = new bytes32[](1);
        input.leafProof[0] = keccak256("leafProof");
        input.rangeHash = keccak256("rangeHash");
        input.dataRootIndex = 5;
        input.blobRoot = keccak256("blobRoot");
        input.bridgeRoot = keccak256("bridgeRoot");
        input.leaf = keccak256("leaf");
        input.leafIndex = 7;
    }

    function _operatorDAInput(IAvailBridge.MerkleProofInput memory _input) internal pure returns (bytes memory) {
        return abi.encodePacked(STATE_DIFF_HASH, abi.encode(_input));
    }

    function test_constructor() public view {
        assertEq(address(validator.bridge()), address(bridge));
        assertEq(address(validator.vectorx()), address(bridge.vectorxContract()));
    }

    function test_checkDA() public {
        IAvailBridge.MerkleProofInput memory input = _proofInput();
        bytes32 outputHash = keccak256(abi.encodePacked(STATE_DIFF_HASH, input.leaf));

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, outputHash, _operatorDAInput(input), 6);

        assertEq(output.stateDiffHash, STATE_DIFF_HASH);
        assertEq(output.blobsLinearHashes.length, 6);
        assertEq(output.blobsOpeningCommitments.length, 6);
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(output.blobsLinearHashes[i], bytes32(0));
            assertEq(output.blobsOpeningCommitments[i], bytes32(0));
        }

        (address attester, uint32 blockNumber, uint128 leafIndex) = validator.attestations(input.leaf);
        assertEq(attester, address(this));
        // DummyVectorX starts every range at block 1.
        assertEq(blockNumber, 1 + 5 + 1);
        assertEq(leafIndex, 7);
    }

    function test_checkDA_RevertWhen_InvalidOutputHash() public {
        IAvailBridge.MerkleProofInput memory input = _proofInput();

        vm.expectRevert(InvalidValidatorOutputHash.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, keccak256("wrong"), _operatorDAInput(input), 6);
    }

    function test_checkDA_RevertWhen_InvalidAttestationProof() public {
        IAvailBridge.MerkleProofInput memory input = _proofInput();
        bytes32 outputHash = keccak256(abi.encodePacked(STATE_DIFF_HASH, input.leaf));
        vm.mockCall(address(bridge), abi.encodeCall(IAvailBridge.verifyBlobLeaf, (input)), abi.encode(false));

        vm.expectRevert(InvalidAttestationProof.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, _operatorDAInput(input), 6);
    }
}
