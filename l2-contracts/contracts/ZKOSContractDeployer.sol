// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IZKOSContractDeployer} from "./interfaces/IZKOSContractDeployer.sol";
import {SET_BYTECODE_ON_ADDRESS_HOOK, COMPLEX_UPGRADER_SYSTEM_CONTRACT} from "./L2ContractHelper.sol";
import {SetBytecodeOnAddressHookFailed, Unauthorized} from "./errors/L2ContractErrors.sol";

/// @title ZKOSContractDeployer
/// @notice Minimal wrapper that forwards to the set bytecode on address system hook at a hardcoded address.
contract ZKOSContractDeployer is IZKOSContractDeployer {
    /// @notice Checks that the message sender is the native token vault.
    modifier onlyComplexUpgrader() {
        if (msg.sender != COMPLEX_UPGRADER_SYSTEM_CONTRACT) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IZKOSContractDeployer
    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash,
        uint32 _observableBytecodeLength
    ) external override onlyComplexUpgrader {
        (bool ok, ) = SET_BYTECODE_ON_ADDRESS_HOOK.call(
            abi.encode(_addr, _bytecodeHash, _bytecodeLength, _observableBytecodeHash, _observableBytecodeLength)
        );

        if (!ok) {
            revert SetBytecodeOnAddressHookFailed();
        }
    }
}
