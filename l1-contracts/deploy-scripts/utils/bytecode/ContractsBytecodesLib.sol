// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BytecodeUtils as Utils} from "./BytecodeUtils.s.sol";

/// @title ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
///         Handles special-case filename/contract-name mismatches (e.g. Admin.sol → AdminFacet).
library ContractsBytecodesLib {
    /// @notice Get L2 deployed bytecode for factory deps, from `out/`.
    function getL2DeployedBytecode(string memory _contractName) internal view returns (bytes memory) {
        string memory fileName = string.concat(_contractName, ".sol");
        return Utils.readDeployedBytecodeL1(fileName, _contractName);
    }

    /// @notice Reads the bytecode of the specified contract using a unique identifier.
    /// @param contractIdentifier A unique string identifying the contract and its source.
    /// Examples: "Bridgehub" (L1 generic), "SystemTransparentUpgradeableProxy" (System contract),
    /// "ForceDeployUpgrader" (L2 contract), "AdminFacet" (L1 special filename).
    /// @return The bytecode of the contract.
    /// @dev Reverts if the contractIdentifier is unknown or unsupported.

    /// @notice Reads L2 bytecode from `out/`.
    function getL2Bytecode(string memory contractIdentifier) internal view returns (bytes memory) {
        return getCreationCodeEVM(contractIdentifier);
    }

    function getCreationCodeEVM(string memory contractIdentifier) internal view returns (bytes memory) {
        string[5] memory DA_CONTRACT_IDENTIFIERS = [
            "RollupL1DAValidator",
            "BlobsL1DAValidatorZKsyncOS",
            "AvailL1DAValidator",
            "DummyAvailBridge",
            "EIP7702Checker"
        ];

        uint256 DA_CONTRACT_IDENTIFIERS_LENGTH = DA_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < DA_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(DA_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
                return Utils.readDAContractBytecode(contractIdentifier);
            }
        }

        // Special cases: contracts where filename differs from contract name
        if (Utils.compareStrings(contractIdentifier, "AdminFacet")) {
            return Utils.readBytecodeL1("Admin.sol", "AdminFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MailboxFacet")) {
            return Utils.readBytecodeL1("Mailbox.sol", "MailboxFacet");
        } else if (Utils.compareStrings(contractIdentifier, "ExecutorFacet")) {
            return Utils.readBytecodeL1("Executor.sol", "ExecutorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "GettersFacet")) {
            return Utils.readBytecodeL1("Getters.sol", "GettersFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MigratorFacet")) {
            return Utils.readBytecodeL1("Migrator.sol", "MigratorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "CommitterFacet")) {
            return Utils.readBytecodeL1("Committer.sol", "CommitterFacet");
        } else if (Utils.compareStrings(contractIdentifier, "BridgedTokenBeacon")) {
            return Utils.readBytecodeL1("UpgradeableBeacon.sol", "UpgradeableBeacon");
        }

        // Default: read from l1-contracts/out/ using standard naming
        return Utils.readBytecodeL1(string.concat(contractIdentifier, ".sol"), contractIdentifier);
    }
}
