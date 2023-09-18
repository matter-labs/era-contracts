// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "./IBridgeheadMailbox.sol";
import "./IProofChainGovernance.sol";
import "./IProofChainExecutor.sol";
import "./IProofDiamondCut.sol";
import "./IProofChainGetters.sol";

// kl to do remove this, needed for the server for now
import "../../common/libraries/Diamond.sol";

interface IProofChain is IProofGovernance, IProofExecutor, IProofGetters {
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

    // KL todo: need this in the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );
}
