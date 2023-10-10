// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../chain-interfaces/IExecutor.sol";
import "./IVerifier.sol";

interface IDiamondInit {
    function initialize(
        uint256 _chainId,
        address _bridgeheadChainContract,
        address _governor,
        bytes32 _storedBatchZero,
        address _allowList,
        address _verifier,
        VerifierParams calldata _verifierParams,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        uint256 _priorityTxMaxGasLimit
    ) external returns (bytes32);
}
