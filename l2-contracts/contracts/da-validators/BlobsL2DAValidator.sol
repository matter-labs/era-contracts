import { IL2DAValidator } from "../interfaces/IL2DAValidator.sol";
import { SystemContractHelper } from "../../../system-contracts/contracts/libraries/SystemContractHelper.sol";
import { SystemLogKey } from "../../../system-contracts/contracts/Constants.sol";

contract BlobsL2DAValidator is IL2DAValidator {
    function produceDACommitment(
        bytes calldata _l2ToL1Pubdata,
        bytes32 calldata _uncompressedStateDiffsHash,
        uint8 _blobsUsed
    ) external {
        bytes32 pubdataHash = keccak256(_l2ToL1Pubdata);

        outputHash = keccak256(abi.encodePacked(_uncompressedStateDiffsHash, pubdataHash, _blobsUsed));

        SystemContractHelper.toL1(true, bytes32(uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY)), outputHash);
    }
}
