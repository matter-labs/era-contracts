// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BytecodeUtils as Utils} from "./BytecodeUtils.s.sol";

/// @title ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
library ContractsBytecodesLib {
    /// @notice Reads the bytecode of the specified contract using a unique identifier.
    /// @param contractIdentifier A unique string identifying the contract and its source.
    /// Examples: "Bridgehub" (L1 generic), "SystemTransparentUpgradeableProxy" (System contract),
    /// "ForceDeployUpgrader" (L2 contract), "AdminFacet" (L1 special filename).
    /// @return The bytecode of the contract.
    /// @dev Reverts if the contractIdentifier is unknown or unsupported.

    function getCreationCode(string memory contractIdentifier) internal view returns (bytes memory) {
        return getCreationCodeZK(contractIdentifier);
    }

    function getCreationCode(string memory contractIdentifier, bool isZKBytecode) internal view returns (bytes memory) {
        if (isZKBytecode) {
            return getCreationCodeZK(contractIdentifier);
        } else {
            return getCreationCodeEVM(contractIdentifier);
        }
    }

    function getCreationCodeEVM(string memory contractIdentifier) internal view returns (bytes memory) {
        string[5] memory EVM_CONTRACT_IDENTIFIERS = [
            "RollupL1DAValidator",
            "BlobsL1DAValidatorZKsyncOS",
            "AvailL1DAValidator",
            "DummyAvailBridge",
            "EIP7702Checker"
        ];

        uint256 DA_CONTRACT_IDENTIFIERS_LENGTH = EVM_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < DA_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(EVM_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
                return Utils.readDAContractBytecode(contractIdentifier);
            }
        }

        revert(
            string.concat("ContractsBytecodesLib: Unknown or unsupported EVM contract identifier: ", contractIdentifier)
        );
    }

    function getCreationCodeZK(string memory contractIdentifier) internal view returns (bytes memory) {
        // Defines the contract identifiers for L1 contracts that follow the
        // pattern: ContractIdentifier.sol and contract class ContractIdentifier.
        // These are handled by the generic L1 case in getCreationCode.
        string[47] memory L1_GENERIC_CONTRACT_IDENTIFIERS = [
            "AccessControlRestriction", /// ??
            "L2AssetTracker",
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
            "ChainRegistrar",
            "EraChainTypeManager",
            "ZKsyncOSChainTypeManager",
            "CTMDeploymentTracker",
            "DiamondInit",
            "DiamondProxy",
            "DefaultUpgrade",
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
            return Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
        } else if (Utils.compareStrings(contractIdentifier, "MailboxFacet")) {
            // Original: Mailbox.sol
            return Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
        } else if (Utils.compareStrings(contractIdentifier, "ExecutorFacet")) {
            // Original: Executor.sol
            return Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
        } else if (Utils.compareStrings(contractIdentifier, "GettersFacet")) {
            // Original: Getters.sol
            return Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
        } else if (Utils.compareStrings(contractIdentifier, "EraVerifierFflonk")) {
            return Utils.readZKFoundryBytecodeL1("EraVerifierFflonk.sol", "EraVerifierFflonk");
        } else if (Utils.compareStrings(contractIdentifier, "EraVerifierPlonk")) {
            return Utils.readZKFoundryBytecodeL1("EraVerifierPlonk.sol", "EraVerifierPlonk");
        } else if (Utils.compareStrings(contractIdentifier, "ZKsyncOSVerifierFflonk")) {
            return Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierFflonk.sol", "ZKsyncOSVerifierFflonk");
        } else if (Utils.compareStrings(contractIdentifier, "ZKsyncOSVerifierPlonk")) {
            return Utils.readZKFoundryBytecodeL1("ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk");
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
                return Utils.readZKFoundryBytecodeL1(string.concat(contractIdentifier, ".sol"), contractIdentifier);
            }
        }

        revert(
            string.concat("ContractsBytecodesLib: Unknown or unsupported ZK contract identifier: ", contractIdentifier)
        );
    }
}
