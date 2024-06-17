interface IL2DAValidator {
    function produceDACommitment(
        bytes calldata _l2ToL1Pubdata,
        bytes32 calldata _uncompressedStateDiffsHash,
        uint8 _blobsUsed
    ) external view returns (bytes32 outputHash);
}
