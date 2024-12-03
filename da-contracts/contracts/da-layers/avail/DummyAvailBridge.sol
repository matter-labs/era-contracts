import {IAvailBridge} from "./IAvailBridge.sol";
import {IVectorx} from "./IVectorx.sol";
import {DummyVectorX} from "./DummyVectorX.sol";

contract DummyAvailBridge is IAvailBridge {
    IVectorx vectorxContract;

    constructor() {
        vectorxContract = new DummyVectorX();
    }

    function vectorx() external view returns (IVectorx) {
        return vectorxContract;
    }

    function verifyBlobLeaf(MerkleProofInput calldata input) external view returns (bool) {
        return true;
    }
}
