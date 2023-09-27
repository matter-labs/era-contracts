// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../chain-interfaces/IExecutor.sol";
import "../../common/libraries/Diamond.sol";
import "../../bridgehead/bridgehead-interfaces/IBridgeheadForProof.sol";
import "./facets/Base.sol";
import "../Config.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is ProofChainBase {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice zkSync contract initialization
    /// @param _verifier address of Verifier contract
    /// @param _governor address who can manage the contract
    /// @param _allowList The address of the allow list smart contract
    /// @param _verifierParams Verifier config parameters that describes the circuit to be verified
    /// @param _l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
    /// @param _l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
    /// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(
        uint256 _chainId,
        address _bridgeheadChainContract,
        address _governor,
        bytes32 _blockHashZero,
        IAllowList _allowList,
        IVerifier _verifier,
        VerifierParams calldata _verifierParams,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        uint256 _priorityTxMaxGasLimit
    ) external reentrancyGuardInitializer returns (bytes32) {
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

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
