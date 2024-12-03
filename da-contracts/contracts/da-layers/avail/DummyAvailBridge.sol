import {IAvailBridge} from "./IAvailBridge.sol";
import {IVectorx} from "./IVectorx.sol";
import {DummyVectorX} from "./DummyVectorX.sol";

contract DummyAvailBridge is IAvailBridge {
    IVectorx vectorxContract;

    constructor() {
        vectorxContract = new DummyVectorX();
    }

    function setPaused(bool status) external {}

    function updateVectorx(address newVectorx) external {}

    function updateTokens(bytes32[] calldata assetIds, address[] calldata tokenAddresses) external {}

    function updateFeePerByte(uint256 newFeePerByte) external {}

    function updateFeeRecipient(address newFeeRecipient) external {}

    function withdrawFees() external {}

    function receiveMessage(Message calldata message, MerkleProofInput calldata input) external {}

    function receiveAVAIL(Message calldata message, MerkleProofInput calldata input) external {}

    function receiveETH(Message calldata message, MerkleProofInput calldata input) external {}

    function receiveERC20(Message calldata message, MerkleProofInput calldata input) external {}

    function sendMessage(bytes32 recipient, bytes calldata data) external payable {}

    function sendAVAIL(bytes32 recipient, uint256 amount) external {}

    function sendETH(bytes32 recipient) external payable {}

    function sendERC20(bytes32 assetId, bytes32 recipient, uint256 amount) external {}

    function vectorx() external view returns (IVectorx) {
        return vectorxContract;
    }

    function verifyBlobLeaf(MerkleProofInput calldata input) external view returns (bool) {
        return true;
    }

    function verifyBridgeLeaf(MerkleProofInput calldata input) external view returns (bool) {
        return true;
    }
}
