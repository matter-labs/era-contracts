// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../interfaces/IGovernance.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "./Base.sol";

/// @title Governance Contract controls access rights for contract management.
/// @author Matter Labs
contract GovernanceFacet is Base, IGovernance {
    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = s.pendingGovernor;

        if (oldPendingGovernor != _newPendingGovernor) {
            // Change pending governor
            s.pendingGovernor = _newPendingGovernor;

            emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
        }
    }

    /// @notice Accepts transfer of admin rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = s.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        if (pendingGovernor != s.governor) {
            address previousGovernor = s.governor;
            s.governor = pendingGovernor;
            delete s.pendingGovernor;

            emit NewPendingGovernor(pendingGovernor, address(0));
            emit NewGovernor(previousGovernor, pendingGovernor);
        }
    }

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external onlyGovernor {
        if (s.validators[_validator] != _active) {
            s.validators[_validator] = _active;
            emit ValidatorStatusUpdate(_validator, _active);
        }
    }

    /// @notice Change bootloader bytecode hash, that is used on L2
    /// @param _l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
    function setL2BootloaderBytecodeHash(bytes32 _l2BootloaderBytecodeHash) external onlyGovernor {
        L2ContractHelper.validateBytecodeHash(_l2BootloaderBytecodeHash);

        // Save previous value into the stack to put it into the event later
        bytes32 previousBootloaderBytecodeHash = s.l2BootloaderBytecodeHash;

        if (previousBootloaderBytecodeHash != _l2BootloaderBytecodeHash) {
            // Change the bootloader bytecode hash
            s.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
            emit NewL2BootloaderBytecodeHash(previousBootloaderBytecodeHash, _l2BootloaderBytecodeHash);
        }
    }

    /// @notice Change default account bytecode hash, that is used on L2
    /// @param _l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
    function setL2DefaultAccountBytecodeHash(bytes32 _l2DefaultAccountBytecodeHash) external onlyGovernor {
        L2ContractHelper.validateBytecodeHash(_l2DefaultAccountBytecodeHash);

        // Save previous value into the stack to put it into the event later
        bytes32 previousDefaultAccountBytecodeHash = s.l2DefaultAccountBytecodeHash;

        if (previousDefaultAccountBytecodeHash != _l2DefaultAccountBytecodeHash) {
            // Change the default account bytecode hash
            s.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
            emit NewL2DefaultAccountBytecodeHash(previousDefaultAccountBytecodeHash, _l2DefaultAccountBytecodeHash);
        }
    }

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyGovernor {
        if (s.zkPorterIsAvailable != _zkPorterIsAvailable) {
            // Change the porter availability
            s.zkPorterIsAvailable = _zkPorterIsAvailable;
            emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
        }
    }

    /// @notice Change the address of the verifier smart contract
    /// @param _newVerifier Verifier smart contract address
    function setVerifier(Verifier _newVerifier) external onlyGovernor {
        Verifier oldVerifier = s.verifier;
        if (oldVerifier != _newVerifier) {
            s.verifier = _newVerifier;
            emit NewVerifier(address(oldVerifier), address(_newVerifier));
        }
    }

    /// @notice Change the verifier parameters
    /// @param _newVerifierParams New parameters for the verifier
    function setVerifierParams(VerifierParams calldata _newVerifierParams) external onlyGovernor {
        VerifierParams memory oldVerifierParams = s.verifierParams;

        s.verifierParams = _newVerifierParams;
        emit NewVerifierParams(oldVerifierParams, _newVerifierParams);
    }

    /// @notice Change the address of the allow list smart contract
    /// @param _newAllowList Allow list smart contract address
    function setAllowList(IAllowList _newAllowList) external onlyGovernor {
        IAllowList oldAllowList = s.allowList;
        if (oldAllowList != _newAllowList) {
            s.allowList = _newAllowList;
            emit NewAllowList(address(oldAllowList), address(_newAllowList));
        }
    }

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyGovernor {
        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        if (oldPriorityTxMaxGasLimit != _newPriorityTxMaxGasLimit) {
            s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
            emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
        }
    }
}
