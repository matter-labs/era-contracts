// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./chain-interfaces/IProofChain.sol";

import "./chain-deps/facets/ProofChainExecutor.sol";
import "./chain-deps/facets/ProofChainGetters.sol";
import "./chain-deps/facets/ProofChainGovernance.sol";

contract ProofChain is IProofChain, ProofExecutorFacet, ProofGettersFacet, ProofGovernanceFacet {
    /// @notice zkSync contract initialization
    /// @param _governor address who can manage the contract
    /// @param _allowList The address of the allow list smart contract
    /// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
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
    ) external reentrancyGuardInitializer {
        require(_governor != address(0), "vy");

        chainStorage.chainId = _chainId;
        chainStorage.bridgeheadChainContract = _bridgeheadChainContract;

        chainStorage.verifier = _verifier;
        chainStorage.governor = _governor;

        chainStorage.storedBlockHashes[0] = _blockHashZero;
        chainStorage.allowList = _allowList;
        chainStorage.verifierParams = _verifierParams;
        chainStorage.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
        chainStorage.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
        chainStorage.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }
}
