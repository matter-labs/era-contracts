// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    DEFAULT_PRIORITY_TX_MAX_PUBDATA,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    UPGRADE_TX_MAX_GAS_LIMIT,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Every L2 protocol upgrade transaction the protocol composes — a transition's, the
///         bootstrap's (the same `buildL2UpgradeTxFromPlan`) and a new chain's genesis — has the
///         shape the per-chain checks of `BaseZkSyncUpgrade._setL2SystemContractUpgrade` require.
///         Those checks stay on chain because they are shared with user transactions and owner
///         recovery cuts; this suite shows the composed transactions never trip them (base-10,
///         base-12, base-15, base-16, boot-68).
contract UpgradeTransactionShapeTest is CTMUpgradeExecutorFixture {
    function test_theTransitionCompositionIsACanonicalUpgradeTransaction() public view {
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition)),
            address(bridgehub),
            chainId
        );
        _assertCanonical(transaction, newVersion);
        assertEq(
            keccak256(abi.encode(transaction.factoryDeps)),
            keccak256(abi.encode(transition.l2Plan().factoryDepHashes)),
            "the factory dependencies are the plan's"
        );
    }

    function test_theGenesisCompositionIsACanonicalUpgradeTransaction() public view {
        L2CanonicalTransaction memory transaction = genesisUpgradeContract.genesisUpgradeTx(
            address(release),
            address(bridgehub),
            chainId,
            newVersion
        );
        _assertCanonical(transaction, newVersion);
        assertEq(transaction.factoryDeps.length, 0, "genesis carries no factory dependencies");
    }

    /// @dev The nonce is the version without its patch component, which `BaseZkSyncUpgrade`
    ///      requires to equal the new minor: true for every major-0 version, the only ones
    ///      `VersionEdgeLib` lets an edge reach.
    function testFuzz_theNonceIsTheMinorOfEveryMajorZeroVersion(uint32 _minor, uint32 _patch) public pure {
        L2CanonicalTransaction memory transaction = L2CanonicalTransactionLib.upgradeTransaction(
            SemVer.packSemVer(0, _minor, _patch),
            hex"c0de"
        );
        assertEq(transaction.nonce, _minor, "nonce == minor");
    }

    function _assertCanonical(L2CanonicalTransaction memory _transaction, uint256 _version) internal pure {
        assertEq(_transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "the upgrade transaction type");
        assertEq(_transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)), "sent by the force deployer");
        assertEq(_transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)), "to the complex upgrader");
        assertEq(_transaction.gasLimit, UPGRADE_TX_MAX_GAS_LIMIT, "gasLimit == UPGRADE_TX_MAX_GAS_LIMIT");
        assertEq(_transaction.gasPerPubdataByteLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "gas per pubdata");
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(_version));
        assertEq(_transaction.nonce, minor, "nonce == the new minor");
        // The checks the engine runs per chain, with the default fee params of a new chain.
        TransactionValidator.validateL1ToL2Transaction(
            _transaction,
            UPGRADE_TX_MAX_GAS_LIMIT,
            DEFAULT_PRIORITY_TX_MAX_PUBDATA
        );
        TransactionValidator.validateUpgradeTransaction(_transaction);
    }
}
