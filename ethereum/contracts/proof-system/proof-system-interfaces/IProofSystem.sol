// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IProofRegistry.sol";
import "../Verifier.sol";
import "../../common/interfaces/IAllowList.sol";
import "../chain-interfaces/IVerifier.sol";

interface IProofSystem is IProofRegistry {
    function initialize(
        uint256 _chainId,
        address _bridgeheadChainContract,
        address _governor,
        IAllowList _allowList,
        Verifier _verifier,
        VerifierParams calldata _verifierParams,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        bytes32 _blockHashZero,
        uint256 _priorityTxMaxGasLimit
    ) external;

    function setVerifierParams(VerifierParams calldata _verifierParams) external;
}
