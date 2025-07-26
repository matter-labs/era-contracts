// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Utils.sol";
import {AllContracts} from "contracts/bridgehub/IContractRegistry.sol";

/// @title ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
library ContractsBytecodesLib {
    /// @notice Reads the bytecode of the specified contract using a unique identifier.
    /// @param contractIdentifier A unique string identifying the contract and its source.
    /// Examples: "Bridgehub" (L1 generic), "SystemTransparentUpgradeableProxy" (System contract),
    /// "ForceDeployUpgrader" (L2 contract), "AdminFacet" (L1 special filename).
    /// @return The bytecode of the contract.
    /// @dev Reverts if the contractIdentifier is unknown or unsupported.

    function getCreationCode(AllContracts contractIdentifier) internal view returns (bytes memory) {
        return getCreationCodeZK(contractIdentifier);
    }

    function getCreationCode(AllContracts contractIdentifier, bool isZKBytecode) internal view returns (bytes memory) {
        if (isZKBytecode) {
            return getCreationCodeZK(contractIdentifier);
        } else {
            return getCreationCodeEVM(contractIdentifier);
        }
    }
    function getCreationCodeEVM(AllContracts contractIdentifier) internal view returns (bytes memory) {
        AllContracts[3] memory DA_CONTRACT_IDENTIFIERS = [AllContracts.RollupL1DAValidator, AllContracts.AvailL1DAValidator, AllContracts.DummyAvailBridge];

        uint256 DA_CONTRACT_IDENTIFIERS_LENGTH = DA_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < DA_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (DA_CONTRACT_IDENTIFIERS[i] == contractIdentifier) {
                return Utils.readDAContractBytecode(contractIdentifier);
            }
        }

        revert(
            string.concat("ContractsBytecodesLib: Unknown or unsupported EVM contract identifier: ", Utils.getDeployedContractName(contractIdentifier))
        );
    }

    function getCreationCodeZK(AllContracts contractIdentifier) internal view returns (bytes memory) {
        // Defines the contract identifiers for L1 contracts that follow the
        // pattern: ContractIdentifier.sol and contract class ContractIdentifier.
        // These are handled by the generic L1 case in getCreationCode.
        AllContracts[36] memory L1_GENERIC_CONTRACT_IDENTIFIERS = [
            AllContracts.AccessControlRestriction, /// ??
            AllContracts.BeaconProxy,
            AllContracts.BridgedStandardERC20,
            AllContracts.BridgedTokenBeacon,
            AllContracts.Bridgehub,
            AllContracts.BytecodesSupplier, // ???
            AllContracts.ChainAdmin,
            AllContracts.ChainAdminOwnable,
            AllContracts.ChainAssetHandler,
            AllContracts.ChainRegistrar,
            AllContracts.ChainTypeManager,
            AllContracts.CTMDeploymentTracker,
            AllContracts.DiamondInit,
            AllContracts.DiamondProxy,
            AllContracts.DefaultUpgrade,
            AllContracts.DualVerifier,
            AllContracts.L1GenesisUpgrade,
            AllContracts.L2AdminFactory,
            AllContracts.L2AssetRouter,
            AllContracts.L2NativeTokenVault,
            AllContracts.L2SharedBridgeLegacy,
            AllContracts.L2SharedBridgeLegacyDev,
            AllContracts.TestnetVerifier,
            AllContracts.L2ProxyAdminDeployer,
            AllContracts.L2WrappedBaseToken,
            AllContracts.Multicall3,
            AllContracts.MessageRoot,
            AllContracts.PermanentRestriction,
            AllContracts.ProxyAdmin, // ??
            AllContracts.UpgradeableBeacon,
            AllContracts.RelayedSLDAValidator,
            AllContracts.RollupDAManager, // ???
            AllContracts.TransparentUpgradeableProxy,
            AllContracts.ServerNotifier, // ???
            AllContracts.ValidatorTimelock,
            AllContracts.ValidiumL1DAValidator // ???
        ];

        AllContracts[6] memory L2_GENERIC_CONTRACT_IDENTIFIERS = [
            AllContracts.ForceDeployUpgrader,
            AllContracts.RollupL2DAValidator,
            AllContracts.ConsensusRegistry,
            AllContracts.AvailL2DAValidator,
            AllContracts.ValidiumL2DAValidator,
            AllContracts.TimestampAsserter
        ];

        AllContracts[3] memory SYSTEM_CONTRACT_IDENTIFIERS = [
            AllContracts.SystemTransparentUpgradeableProxy,
            AllContracts.L2GatewayUpgrade,
            AllContracts.L2V29Upgrade
        ];

        // --- Special Cases: System Contracts ---
        // These contracts are typically read from a 'system-contracts' or similar directory.
        if (contractIdentifier == AllContracts.SystemTransparentUpgradeableProxy) {
            return
                Utils.readZKFoundryBytecodeSystemContracts(
                    "TransparentUpgradeableProxy.sol",
                    "TransparentUpgradeableProxy"
                );
        }

        // --- Special Cases: L1 Contracts with specific file/contract names ---
        // These L1 contracts do not follow the direct ContractIdentifier.sol mapping.
        if (contractIdentifier == AllContracts.AdminFacet) {
            // Original: Admin.sol
            return Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
        } else if (contractIdentifier == AllContracts.MailboxFacet) {
            // Original: Mailbox.sol
            return Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
        } else if (contractIdentifier == AllContracts.ExecutorFacet) {
            // Original: Executor.sol
            return Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
        } else if (contractIdentifier == AllContracts.GettersFacet) {
            // Original: Getters.sol
            return Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
        } else if (contractIdentifier == AllContracts.VerifierFflonk) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierFflonk.sol", "L1VerifierFflonk");
        } else if (contractIdentifier == AllContracts.VerifierPlonk) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierPlonk.sol", "L1VerifierPlonk");
        }

        // --- General Cases ---
        // Checks if contractIdentifier is in CONTRACT_IDENTIFIERS.
        // If so, loads ContractIdentifier.sol and expects contract class ContractIdentifier.
        uint256 SYSTEM_CONTRACT_IDENTIFIERS_LENGTH = SYSTEM_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < SYSTEM_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (SYSTEM_CONTRACT_IDENTIFIERS[i] == contractIdentifier) {
                // The contractIdentifier itself is used for both filename and contract name.
                return
                    Utils.readZKFoundryBytecodeSystemContracts(
                        string.concat(Utils.getDeployedContractName(contractIdentifier), ".sol"),
                        Utils.getDeployedContractName(contractIdentifier)
                    );
            }
        }

        uint256 L2_GENERIC_CONTRACT_IDENTIFIERS_LENGTH = L2_GENERIC_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < L2_GENERIC_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (L2_GENERIC_CONTRACT_IDENTIFIERS[i] == contractIdentifier) {
                return Utils.readZKFoundryBytecodeL2(string.concat(Utils.getDeployedContractName(contractIdentifier), ".sol"), Utils.getDeployedContractName(contractIdentifier));
            }
        }

        uint256 L1_GENERIC_CONTRACT_IDENTIFIERS_LENGTH = L1_GENERIC_CONTRACT_IDENTIFIERS.length;
        for (uint i = 0; i < L1_GENERIC_CONTRACT_IDENTIFIERS_LENGTH; i++) {
            if (L1_GENERIC_CONTRACT_IDENTIFIERS[i] == contractIdentifier) {
                // The contractIdentifier itself is used for both filename and contract name.
                return Utils.readZKFoundryBytecodeL1(string.concat(Utils.getDeployedContractName(contractIdentifier), ".sol"), Utils.getDeployedContractName(contractIdentifier));
            }
        }

        revert(
            string.concat("ContractsBytecodesLib: Unknown or unsupported ZK contract identifier: ", Utils.getDeployedContractName(contractIdentifier))
        );
    }
}
