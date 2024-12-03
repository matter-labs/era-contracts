import {IVectorx} from "./IVectorx.sol";

contract DummyVectorX is IVectorx {
    function rangeStartBlocks(bytes32 rangeHash) external view returns (uint32 startBlock) {
        return 1;
    }
}
