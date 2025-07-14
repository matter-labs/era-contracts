// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAvailBridge} from "./IAvailBridge.sol";
import {IVectorx} from "./IVectorx.sol";
import {DummyVectorX} from "./DummyVectorX.sol";

contract DummyAvailBridge is IAvailBridge {
    IVectorx public vectorxContract;

    constructor() {
        vectorxContract = new DummyVectorX();
    }

    function vectorx() external view returns (IVectorx) {
        return vectorxContract;
    }

    function verifyBlobLeaf(MerkleProofInput calldata) external view returns (bool) {
        return true;
    }
}
