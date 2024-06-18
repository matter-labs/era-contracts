import {IL2DAValidator} from "../interfaces/IL2DAValidator.sol";
import { SystemContractHelper } from "../../../system-contracts/contracts/libraries/SystemContractHelper.sol";
import { SystemLogKey } from "../../../system-contracts/contracts/Constants.sol";

contract CalldataL2DAValidator is IL2DAValidator {
    function produceDACommitment(
        bytes calldata _l2ToL1Pubdata,
        bytes32 calldata _uncompressedStateDiffsHash,
        uint8 _blobsUsed
    ) external view returns (bytes32 outputHash){
        bytes32 _pubdataHash = keccak256(_l2ToL1Pubdata);

        // The number 1 is hardcoded here, because 1 blob is enough to store the calldata
        outputHash = keccak256(abi.encodePacked(_uncompressedStateDiffsHash, _pubdataHash, 1));
        SystemContractHelper.toL1(true, bytes32(uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY)), outputHash);
    }
}
