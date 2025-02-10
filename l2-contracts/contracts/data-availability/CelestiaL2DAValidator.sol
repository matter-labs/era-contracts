pragma solidity 0.8.24;

import {IL2DAValidator} from "../interfaces/IL2DAValidator.sol";
import {StateDiffL2DAValidator} from "./StateDiffL2DAValidator.sol";

contract CelestiaL2DAValidator is IL2DAValidator, StateDiffL2DAValidator {
    function validatePubdata(bytes32, bytes32, bytes32, bytes32, bytes calldata) external returns (bytes32) {
        (bytes32 stateDiffHash, bytes calldata _totalPubdata, ) = _produceStateDiffPubdata(
            _chainedMessagesHash,
            _chainedBytecodesHash,
            _totalL2ToL1PubdataAndStateDiffs
        );

        bytes32 fullPubdataHash = keccak256(_totalPubdata);
        return keccak256(abi.encodePacked(stateDiffHash, fullPubdataHash));
    }
}
