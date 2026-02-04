// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_COMPLEX_UPGRADER_ADDR, SET_BYTECODE_ON_ADDRESS_HOOK} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IZKOSContractDeployer} from "./interfaces/IZKOSContractDeployer.sol";
import {SetBytecodeOnAddressHookFailed, Unauthorized} from "./errors/ZKOSContractErrors.sol";

/// @title ZKOSContractDeployer
/// @notice Minimal wrapper that forwards to the set bytecode on address system hook at a hardcoded address.
contract ZKOSContractDeployer is IZKOSContractDeployer {
    /// @notice Checks that the message sender is the native token vault.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IZKOSContractDeployer
    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external override onlyComplexUpgrader {
        (bool ok, ) = SET_BYTECODE_ON_ADDRESS_HOOK.call(
            abi.encode(_addr, _bytecodeHash, _bytecodeLength, _observableBytecodeHash)
        );

        if (!ok) {
            revert SetBytecodeOnAddressHookFailed();
        }
    }
}
