// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {VerifierParams} from "../chain-interfaces/IVerifier.sol";

/// @notice The struct that represents the upgrade proposal.
/// @param l2ProtocolUpgradeTx The system upgrade transaction.
/// @param bootloaderHash The hash of the new bootloader bytecode. If zero, it will not be updated.
/// @param defaultAccountHash The hash of the new default account bytecode. If zero, it will not be updated.
/// @param evmEmulatorHash The hash of the new EVM emulator bytecode. If zero, it will not be updated.
/// @param verifier Deprecated. Verifier is fetched from CTM based on protocol version.
/// @param verifierParams Deprecated. Verifier params are kept for backward compatibility.
/// @param l1ContractsUpgradeCalldata Custom calldata for L1 contracts upgrade, it may be interpreted differently
/// in each upgrade. Usually empty.
/// @param postUpgradeCalldata Custom calldata for post upgrade hook, it may be interpreted differently in each
/// upgrade. Usually empty.
/// @param upgradeTimestamp The timestamp after which the upgrade can be executed.
/// @param newProtocolVersion The new version number for the protocol after this upgrade. Should be greater than
/// the previous protocol version.
struct ProposedUpgrade {
    L2CanonicalTransaction l2ProtocolUpgradeTx;
    bytes32 bootloaderHash;
    bytes32 defaultAccountHash;
    bytes32 evmEmulatorHash;
    address verifier;
    VerifierParams verifierParams;
    bytes l1ContractsUpgradeCalldata;
    bytes postUpgradeCalldata;
    uint256 upgradeTimestamp;
    uint256 newProtocolVersion;
}

/// @notice Helpers for constructing zero-initialised upgrade structs.
/// @dev Shared between runtime contracts (ChainTypeManagerBase) and deploy scripts (CTMUpgradeBase)
/// to avoid manual zero-struct assembly that can desync when fields change.
library ProposedUpgradeLib {
    function emptyL2CanonicalTransaction() internal pure returns (L2CanonicalTransaction memory) {
        return
            L2CanonicalTransaction({
                txType: 0,
                from: 0,
                to: 0,
                gasLimit: 0,
                gasPerPubdataByteLimit: 0,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                paymaster: 0,
                nonce: 0,
                value: 0,
                reserved: [uint256(0), 0, 0, 0],
                data: "",
                signature: "",
                factoryDeps: new uint256[](0),
                paymasterInput: "",
                reservedDynamic: ""
            });
    }

    function emptyVerifierParams() internal pure returns (VerifierParams memory) {
        return
            VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            });
    }

    function emptyProposedUpgrade(uint256 _newProtocolVersion) internal pure returns (ProposedUpgrade memory) {
        return
            ProposedUpgrade({
                l2ProtocolUpgradeTx: emptyL2CanonicalTransaction(),
                bootloaderHash: bytes32(0),
                defaultAccountHash: bytes32(0),
                evmEmulatorHash: bytes32(0),
                verifier: address(0),
                verifierParams: emptyVerifierParams(),
                l1ContractsUpgradeCalldata: "",
                postUpgradeCalldata: "",
                upgradeTimestamp: 0,
                newProtocolVersion: _newProtocolVersion
            });
    }
}
