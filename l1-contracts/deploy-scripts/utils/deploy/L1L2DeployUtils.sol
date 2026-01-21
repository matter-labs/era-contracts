// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "../Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2_CREATE2_FACTORY_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @title L1L2DeployUtils
/// @notice Utilities for deploying contracts via L1->L2 transactions with support for both
/// Era (zkSync-specific) and ZKsyncOS (standard EVM) CREATE2 modes.
library L1L2DeployUtils {
    /// @notice Result of preparing an L1->L2 deployment
    struct DeployResult {
        address expectedAddress;
        bytes data;
        address targetAddress;
    }

    /// @notice Prepares deployment data for L1->L2 contract deployment.
    /// @dev When isZKsyncOS is true, uses the deterministic CREATE2 factory with standard EVM address derivation.
    ///      When isZKsyncOS is false, uses the ZKsync CREATE2 factory with zkSync-specific address derivation.
    /// @param salt The CREATE2 salt.
    /// @param bytecode The contract bytecode.
    /// @param constructorArgs The constructor arguments.
    /// @param isZKsyncOS Whether to use ZKsyncOS mode (standard EVM CREATE2).
    /// @return result The prepared deployment result containing expected address, data, and target address.
    function prepareDeployment(
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs,
        bool isZKsyncOS
    ) internal view returns (DeployResult memory result) {
        result.targetAddress = getDeploymentTarget(isZKsyncOS);
        if (isZKsyncOS) {
            bytes memory initCode = abi.encodePacked(bytecode, constructorArgs);
            // ZKsyncOS mode: use deterministic CREATE2 factory with standard EVM address derivation
            result.expectedAddress = Utils.getL2AddressViaDeterministicCreate2(salt, initCode);
            result.data = Utils.getDeterministicCreate2FactoryCalldata(salt, initCode);
        } else {
            // Era mode: use ZKsync CREATE2 factory with zkSync-specific address derivation
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);
            result.expectedAddress = Utils.getL2AddressViaCreate2Factory(salt, bytecodeHash, constructorArgs);
            (, result.data) = Utils.getDeploymentCalldata(salt, bytecode, constructorArgs);
        }
    }

    /// @notice Gets the target address for L1->L2 deployment based on mode.
    /// @param isZKsyncOS Whether to use ZKsyncOS mode.
    /// @return The target address for the L1->L2 transaction.
    function getDeploymentTarget(bool isZKsyncOS) internal pure returns (address) {
        return isZKsyncOS ? Utils.DETERMINISTIC_CREATE2_ADDRESS : L2_CREATE2_FACTORY_ADDR;
    }
}
