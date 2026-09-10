// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2ContractDeployer} from "../../../common/interfaces/IL2ContractDeployer.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {L2GenesisForceDeploymentsHelper} from "../../../l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {BYTECODE_INFO_LENGTH, ZKSyncOSBytecodeInfo} from "../../../common/libraries/ZKSyncOSBytecodeInfo.sol";
import {
    L2BytecodeNotInFactoryDeps,
    L2BytecodeNotPublished,
    L2DelegateNotAnExtraDeployment,
    L2ExtraDeploymentNotBytecodeDerived,
    L2ExtraDeploymentNotUnsafe
} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice What L1 CAN establish about a transition's authored L2 remainder, mechanically. The
///         table-derived deployments are a pure function of the release; the authored fields
///         (extras, delegate, factory deps) are reviewed data — but their SHAPE is not a matter
///         of review:
///         - an extra deployment may only be an `Unsafe` deployment at the address DERIVED from
///           its own bytecode info (`keccak256(0x00..00 || info)`, see
///           {L2GenesisForceDeploymentsHelper.generateRandomAddress}), so it cannot land on a
///           fixed built-in or on a table-derived target;
///         - the delegate target must be one of those extras, so the code the upgrade
///           delegatecalls into is pinned by a bytecode hash the manifest carries;
///         - every bytecode any deployment installs must be among the transaction's factory
///           dependencies, and every factory dependency must have been PUBLISHED on the CTM's
///           `BytecodesSupplier` before the upgrade commits.
///         What remains review work is what the delegate DOES — its bytecode hash names an
///         auditable artifact, not a behavior.
library L2PlanValidationLib {
    /// @notice Structural checks over the authored remainder, run at transition construction.
    /// @param _derived The table-derived deployments (see {TransitionDerivationLib}).
    /// @param _extras The authored extra deployments.
    /// @param _delegateTo The authored delegate target (zero when the plan has no delegate leg).
    /// @param _factoryDepHashes The authored factory dependencies (`keccak256` of each bytecode).
    function validateAuthored(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _derived,
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _extras,
        address _delegateTo,
        uint256[] memory _factoryDepHashes
    ) internal pure {
        uint256 extrasLength = _extras.length;
        bool delegateIsExtra = _delegateTo == address(0);
        for (uint256 i = 0; i < extrasLength; ++i) {
            IComplexUpgrader.UniversalContractUpgradeInfo memory extra = _extras[i];
            if (extra.upgradeType != IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment) {
                revert L2ExtraDeploymentNotUnsafe(extra.newAddress);
            }
            // A single canonical bytecode info (no proxy half): the address is a pure function of it.
            address derivedAddress = L2GenesisForceDeploymentsHelper.generateRandomAddress(extra.deployedBytecodeInfo);
            if (extra.deployedBytecodeInfo.length != BYTECODE_INFO_LENGTH || extra.newAddress != derivedAddress) {
                revert L2ExtraDeploymentNotBytecodeDerived(derivedAddress, extra.newAddress);
            }
            if (extra.newAddress == _delegateTo) {
                delegateIsExtra = true;
            }
            _requireInFactoryDeps(_observableHash(extra.deployedBytecodeInfo), _factoryDepHashes);
        }
        if (!delegateIsExtra) {
            revert L2DelegateNotAnExtraDeployment(_delegateTo);
        }

        uint256 derivedLength = _derived.length;
        for (uint256 i = 0; i < derivedLength; ++i) {
            IComplexUpgrader.UniversalContractUpgradeInfo memory row = _derived[i];
            if (row.upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade) {
                // System-proxy rows carry two bytecodes: the implementation and the proxy shell.
                (bytes memory implInfo, bytes memory proxyInfo) = abi.decode(row.deployedBytecodeInfo, (bytes, bytes));
                _requireInFactoryDeps(_observableHash(implInfo), _factoryDepHashes);
                _requireInFactoryDeps(_observableHash(proxyInfo), _factoryDepHashes);
            } else {
                IL2ContractDeployer.ForceDeployment memory forceDeployment = abi.decode(
                    row.deployedBytecodeInfo,
                    (IL2ContractDeployer.ForceDeployment)
                );
                _requireInFactoryDeps(forceDeployment.bytecodeHash, _factoryDepHashes);
            }
        }
    }

    /// @notice Reverts unless every factory dependency has been published on `_supplier`.
    /// @dev Live L1 state, so it belongs where the upgrade COMMITS (the executor's apply and the
    ///      bootstrap's migrate), not at construction: publication can legitimately happen after
    ///      the object is built, and it must hold when the edge is committed or the L2
    ///      transaction fails on every chain.
    function requirePublished(BytecodesSupplier _supplier, uint256[] memory _factoryDepHashes) internal view {
        uint256 length = _factoryDepHashes.length;
        for (uint256 i = 0; i < length; ++i) {
            bytes32 hash = bytes32(_factoryDepHashes[i]);
            if (_supplier.evmPublishingBlock(hash) == 0) {
                revert L2BytecodeNotPublished(hash);
            }
        }
    }

    /// @dev The `keccak256` of the deployed EVM bytecode a ZKsync OS bytecode info describes —
    ///      the same key `BytecodesSupplier` publishes under and the L2 transaction's factory
    ///      dependencies carry.
    function _observableHash(bytes memory _bytecodeInfo) private pure returns (bytes32 observableBytecodeHash) {
        (, , observableBytecodeHash) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(_bytecodeInfo);
    }

    function _requireInFactoryDeps(bytes32 _hash, uint256[] memory _factoryDepHashes) private pure {
        uint256 length = _factoryDepHashes.length;
        for (uint256 i = 0; i < length; ++i) {
            if (bytes32(_factoryDepHashes[i]) == _hash) {
                return;
            }
        }
        revert L2BytecodeNotInFactoryDeps(_hash);
    }
}
