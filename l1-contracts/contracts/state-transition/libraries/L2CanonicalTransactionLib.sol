// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "../../common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "../../common/libraries/SemVer.sol";

/// @notice Helpers for constructing L2 canonical transactions.
/// @dev Shared between runtime contracts (`CTMUpgradeComposer`, `L1GenesisUpgrade`) and deploy
/// scripts (`UpgradeHelperLib`) to avoid manual struct assembly that can desync when fields change.
library L2CanonicalTransactionLib {
    /// @notice The all-zero transaction (`txType == 0`), which `BaseZkSyncUpgrade` treats as "no L2
    ///         protocol upgrade transaction".
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

    /// @notice The canonical envelope of an L1 -> L2 protocol upgrade transaction: the upgrade
    ///         transaction type, the force deployer as sender, the `L2ComplexUpgrader` as
    ///         recipient, the fixed gas fields, the version-derived nonce and the zero remainder.
    ///         Every composition path — a new chain's genesis and a registry-driven upgrade alike —
    ///         differs only in the call the `L2ComplexUpgrader` is asked to perform (and, for the
    ///         upgrade path, the factory dependencies it sets afterwards).
    /// @param _protocolVersion The packed SemVer version the transaction moves the chain to.
    /// @param _complexUpgraderCalldata The call the `L2ComplexUpgrader` performs.
    function upgradeTransaction(
        uint256 _protocolVersion,
        bytes memory _complexUpgraderCalldata
    ) internal pure returns (L2CanonicalTransaction memory transaction) {
        transaction = emptyL2CanonicalTransaction();
        transaction.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(_protocolVersion);
        transaction.data = _complexUpgraderCalldata;
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version — the
    ///         packed version without its patch component, which keeps upgrade transaction hashes
    ///         unique per version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`. `BaseZkSyncUpgrade` enforces that
    ///      the result equals the new MINOR version, which holds because every upgrade path
    ///      rejects a non-zero major version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
