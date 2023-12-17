// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IAdmin.sol";
import "./IExecutor.sol";
import "./IGetters.sol";
import "./IMailbox.sol";

// kl to do remove this, needed for the server for now
import "../../common/libraries/Diamond.sol";

interface IStateTransitionChain is IAdmin, IExecutor, IGetters, IMailbox {
    function initialize(
        uint256 _chainId,
        address _bridgehubChainContract,
        address _governor,
        Verifier _verifier,
        VerifierParams calldata _verifierParams,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        bytes32 _storedBatchZero,
        uint256 _priorityTxMaxGasLimit
    ) external;

    // KL todo: need this in the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );
}
