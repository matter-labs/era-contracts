// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {Utils} from "../Utils.sol";

/// @notice Force-deployment logic that differs between Era and ZKsyncOS.
///         This library is an internal implementation detail of EraZkosRouter.
///         External callers should use EraZkosRouter's public API instead.
library EraZkosForceDeployments {
    /// @notice Compute the bytecode hash used in a ForceDeployment entry.
    ///         Era:      L2ContractHelper.hashL2Bytecode of the ZK creation code.
    ///         ZKsyncOS: keccak256 of the EVM deployed bytecode.
    function getForceDeploymentBytecodeHash(
        string memory _contractName,
        bool _isZKsyncOS
    ) internal view returns (bytes32) {
        string memory fileName = string.concat(_contractName, ".sol");
        if (_isZKsyncOS) {
            return keccak256(Utils.readFoundryDeployedBytecodeL1(fileName, _contractName));
        }
        return L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1(fileName, _contractName));
    }
}
