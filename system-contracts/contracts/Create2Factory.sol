// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {REAL_DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {IContractDeployer} from "./interfaces/IContractDeployer.sol";
import {ICreate2Factory} from "./interfaces/ICreate2Factory.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that can be used for deterministic contract deployment.
contract Create2Factory is ICreate2Factory {
    /// @inheritdoc ICreate2Factory
    function create2(
        bytes32, // _salt
        bytes32, // _bytecodeHash
        bytes calldata // _input
    ) external payable returns (address) {
        _relayCall();
    }

    /// @inheritdoc ICreate2Factory
    function create2Account(
        bytes32, // _salt
        bytes32, // _bytecodeHash
        bytes calldata, // _input
        IContractDeployer.AccountAbstractionVersion // _aaVersion
    ) external payable returns (address) {
        _relayCall();
    }

    /// @notice Function that efficiently relays the calldata to the contract deployer system contract. After that,
    /// it also relays full result.
    function _relayCall() internal {
        bool success = EfficientCall.rawCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _value: msg.value,
            _data: msg.data,
            _isSystem: true
        });

        assembly {
            returndatacopy(0, 0, returndatasize())
            if success {
                return(0, returndatasize())
            }
            revert(0, returndatasize())
        }
    }
}
