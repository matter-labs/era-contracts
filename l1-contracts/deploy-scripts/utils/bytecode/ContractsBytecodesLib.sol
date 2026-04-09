// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BytecodeUtils as Utils} from "./BytecodeUtils.s.sol";

/// @title ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
///         Handles special-case filename/contract-name mismatches (e.g. Admin.sol → AdminFacet).
library ContractsBytecodesLib {
    /// @notice Get L2 deployed bytecode for factory deps.
    ///         EVM bytecodes: EVM deployed bytecode from out/.
    ///         ZK bytecodes: ZK creation code from zkout/.
    function getL2DeployedBytecode(
        string memory _contractName,
        bool _isEVMBytecode
    ) internal view returns (bytes memory) {
        string memory fileName = string.concat(_contractName, ".sol");
        return Utils.readDeployedBytecodeL1(_isEVMBytecode, fileName, _contractName);
    }

    /// @notice Reads the bytecode of the specified contract using a unique identifier.
    /// @param contractIdentifier A unique string identifying the contract and its source.
    /// Examples: "Bridgehub" (L1 generic), "SystemTransparentUpgradeableProxy" (System contract),
    /// "ForceDeployUpgrader" (L2 contract), "AdminFacet" (L1 special filename).
    /// @return The bytecode of the contract.
    /// @dev Reverts if the contractIdentifier is unknown or unsupported.

    function getCreationCode(string memory contractIdentifier, bool isZKBytecode) internal view returns (bytes memory) {
        if (isZKBytecode) {
            return getCreationCodeEra(contractIdentifier);
        } else {
            return getCreationCodeEVM(contractIdentifier);
        }
    }

    /// @notice Reads L2 bytecode: EVM bytecodes from out/, ZK bytecodes from zkout/.
    function getL2Bytecode(string memory contractIdentifier, bool isEVMBytecode) internal view returns (bytes memory) {
        if (isEVMBytecode) {
            return getCreationCodeEVM(contractIdentifier);
        }
        return getCreationCodeEra(contractIdentifier);
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
            return Utils.readBytecodeL1(true, "Admin.sol", "AdminFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MailboxFacet")) {
            return Utils.readBytecodeL1(true, "Mailbox.sol", "MailboxFacet");
        } else if (Utils.compareStrings(contractIdentifier, "ExecutorFacet")) {
            return Utils.readBytecodeL1(true, "Executor.sol", "ExecutorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "GettersFacet")) {
            return Utils.readBytecodeL1(true, "Getters.sol", "GettersFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MigratorFacet")) {
            return Utils.readBytecodeL1(true, "Migrator.sol", "MigratorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "CommitterFacet")) {
            return Utils.readBytecodeL1(true, "Committer.sol", "CommitterFacet");
        } else if (Utils.compareStrings(contractIdentifier, "BridgedTokenBeacon")) {
            return Utils.readBytecodeL1(true, "UpgradeableBeacon.sol", "UpgradeableBeacon");
        }

        // Default: read from l1-contracts/out/ using standard naming
        return Utils.readBytecodeL1(true, string.concat(contractIdentifier, ".sol"), contractIdentifier);
    }

    function getCreationCodeEra(string memory contractIdentifier) internal view returns (bytes memory) {
        // Defines the contract identifiers for L1 contracts that follow the
        // pattern: ContractIdentifier.sol and contract class ContractIdentifier.
        // These are handled by the generic L1 case in getCreationCodeEra.
        string[54] memory L1_GENERIC_CONTRACT_IDENTIFIERS = [
            "AccessControlRestriction",
            /// ??
            "BaseTokenHolder",
            "GWAssetTracker",
            "L2AssetTracker",
            "L2BaseTokenEra",
            "L2BaseTokenZKOS",
            "BeaconProxy",
            "BridgedStandardERC20",
            "BridgedTokenBeacon",
            "L1Bridgehub",
            "L2Bridgehub",
            "BytecodesSupplier", // ???
            "ChainAdmin",
            "ChainAdminOwnable",
            "L1ChainAssetHandler",
            "L2ChainAssetHandler",
            "EraChainTypeManager",
            "ZKsyncOSChainTypeManager",
            "CTMDeploymentTracker",
            "DiamondInit",
            "DiamondProxy",
            "DefaultUpgrade",
            "EraSettlementLayerV31Upgrade",
            "ZKsyncOSSettlementLayerV31Upgrade",
            "InteropCenter",
            "InteropHandler",
            "EraDualVerifier",
            "ZKsyncOSDualVerifier",
            "L1GenesisUpgrade",
            "L2AdminFactory",
            "L2AssetRouter",
            "L2NativeTokenVault",
            "L2SharedBridgeLegacy",
            "L2SharedBridgeLegacyDev",
            "EraTestnetVerifier",
            "L2ProxyAdminDeployer",
            "L2WrappedBaseToken",
            "Multicall3",
            "DummyL1MessageRoot",
            "L1MessageRoot",
            "L2MessageRoot",
            "PermanentRestriction",
            "ProxyAdmin", // ??
            "UpgradeableBeacon",
            "RelayedSLDAValidator",
            "RollupDAManager", // ???
            "TransparentUpgradeableProxy",
            "ServerNotifier", // ???
            "ValidatorTimelock",
            "ValidiumL1DAValidator", // ???
            "L2InteropRootStorage",
            "L2MessageVerification",
            "L2V31Upgrade",
            "UpgradeableBeaconDeployer"
        ];

        string[3] memory L2_GENERIC_CONTRACT_IDENTIFIERS = [
            "ForceDeployUpgrader",
            "ConsensusRegistry",
            "TimestampAsserter"
        ];

        string[2] memory SYSTEM_CONTRACT_IDENTIFIERS = ["SystemTransparentUpgradeableProxy", "L2V29Upgrade"];

        // --- Special Cases: System Contracts ---
        // These contracts are typically read from a 'system-contracts' or similar directory.
        if (Utils.compareStrings(contractIdentifier, "SystemTransparentUpgradeableProxy")) {
            return
                Utils.readZKFoundryBytecodeSystemContracts(
                    "TransparentUpgradeableProxy.sol",
                    "TransparentUpgradeableProxy"
                );
        }

        // --- Special Cases: L1 Contracts with specific file/contract names ---
        // These L1 contracts do not follow the direct ContractIdentifier.sol mapping.
        if (Utils.compareStrings(contractIdentifier, "AdminFacet")) {
            // Original: Admin.sol
            return Utils.readBytecodeL1(false, "Admin.sol", "AdminFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MailboxFacet")) {
            // Original: Mailbox.sol
            return Utils.readBytecodeL1(false, "Mailbox.sol", "MailboxFacet");
        } else if (Utils.compareStrings(contractIdentifier, "ExecutorFacet")) {
            // Original: Executor.sol
            return Utils.readBytecodeL1(false, "Executor.sol", "ExecutorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "GettersFacet")) {
            // Original: Getters.sol
            return Utils.readBytecodeL1(false, "Getters.sol", "GettersFacet");
        } else if (Utils.compareStrings(contractIdentifier, "EraVerifierFflonk")) {
            return Utils.readBytecodeL1(false, "EraVerifierFflonk.sol", "EraVerifierFflonk");
        } else if (Utils.compareStrings(contractIdentifier, "EraVerifierPlonk")) {
            return Utils.readBytecodeL1(false, "EraVerifierPlonk.sol", "EraVerifierPlonk");
        } else if (Utils.compareStrings(contractIdentifier, "ZKsyncOSVerifierFflonk")) {
            return Utils.readBytecodeL1(false, "ZKsyncOSVerifierFflonk.sol", "ZKsyncOSVerifierFflonk");
        } else if (Utils.compareStrings(contractIdentifier, "ZKsyncOSVerifierPlonk")) {
            return Utils.readBytecodeL1(false, "ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk");
        }

        // --- General Cases ---
        // Checks if contractIdentifier is in CONTRACT_IDENTIFIERS.
        // If so, loads ContractIdentifier.sol and expects contract class ContractIdentifier.
        uint256 SYSTEM_CONTRACT_IDENTIFIERS_LENGTH = SYSTEM_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < SYSTEM_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(SYSTEM_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
                // The contractIdentifier itself is used for both filename and contract name.
                return
                    Utils.readZKFoundryBytecodeSystemContracts(
                        string.concat(contractIdentifier, ".sol"),
                        contractIdentifier
                    );
            }
        }

        uint256 L2_GENERIC_CONTRACT_IDENTIFIERS_LENGTH = L2_GENERIC_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < L2_GENERIC_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(L2_GENERIC_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
                return Utils.readZKFoundryBytecodeL2(string.concat(contractIdentifier, ".sol"), contractIdentifier);
            }
        }

        uint256 L1_GENERIC_CONTRACT_IDENTIFIERS_LENGTH = L1_GENERIC_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < L1_GENERIC_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(L1_GENERIC_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
                // The contractIdentifier itself is used for both filename and contract name.
                return Utils.readBytecodeL1(false, string.concat(contractIdentifier, ".sol"), contractIdentifier);
            }
        }

        revert(
            string.concat("ContractsBytecodesLib: Unknown or unsupported ZK contract identifier: ", contractIdentifier)
        );
    }
}
