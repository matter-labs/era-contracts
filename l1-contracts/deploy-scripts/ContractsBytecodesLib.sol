// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Utils as Utils_old} from "./Utils.sol";
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
        string[3] memory DA_CONTRACT_IDENTIFIERS = ["RollupL1DAValidator", "AvailL1DAValidator", "DummyAvailBridge"];

        uint256 DA_CONTRACT_IDENTIFIERS_LENGTH = DA_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < DA_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (Utils.compareStrings(DA_CONTRACT_IDENTIFIERS[i], contractIdentifier)) {
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
        string[38] memory L1_GENERIC_CONTRACT_IDENTIFIERS = [
            "AccessControlRestriction", /// ??
            "BeaconProxy",
            "BridgedStandardERC20",
            "BridgedTokenBeacon",
            "Bridgehub",
            "BytecodesSupplier", // ???
            "ChainAdmin",
            "ChainAdminOwnable",
            "ChainAssetHandler",
            "ChainRegistrar",
            "ChainTypeManager",
            "CTMDeploymentTracker",
            "DiamondInit",
            "DiamondProxy",
            "DefaultUpgrade",
            "DualVerifier",
            "L1GenesisUpgrade",
            "L2AdminFactory",
            "L2AssetRouter",
            "L2NativeTokenVault",
            "L2SharedBridgeLegacy",
            "L2SharedBridgeLegacyDev",
            "TestnetVerifier",
            "L2ProxyAdminDeployer",
            "L2WrappedBaseToken",
            "Multicall3",
            "MessageRoot",
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
            "L1V29Upgrade"
        ];

        string[6] memory L2_GENERIC_CONTRACT_IDENTIFIERS = [
            "ForceDeployUpgrader",
            "RollupL2DAValidator",
            "ConsensusRegistry",
            "AvailL2DAValidator",
            "ValidiumL2DAValidator",
            "TimestampAsserter"
        ];

        string[3] memory SYSTEM_CONTRACT_IDENTIFIERS = [
            "SystemTransparentUpgradeableProxy",
            "L2GatewayUpgrade",
            "L2V29Upgrade"
        ];

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
        } else if (Utils.compareStrings(contractIdentifier, "VerifierFflonk")) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierFflonk.sol", "L1VerifierFflonk");
        } else if (Utils.compareStrings(contractIdentifier, "VerifierPlonk")) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierPlonk.sol", "L1VerifierPlonk");
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
