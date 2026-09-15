// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {L2GenesisForceDeploymentsHelper} from "../../../l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {BYTECODE_INFO_LENGTH, ZKSyncOSBytecodeInfo} from "../../../common/libraries/ZKSyncOSBytecodeInfo.sol";
import {MAX_NEW_FACTORY_DEPS} from "../../../common/Config.sol";
import {L2BytecodeNotPublished, MalformedL2UpgradePlan} from "../../../common/L1ContractErrors.sol";
import {AuthoredL2Plan, L2UpgradePlan} from "../RegistryTypes.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice CONSTRUCTS the final L2 plan of one edge from the table-derived deployments and the
///         authored input, and gates its factory dependencies on publication. Nothing about the
///         L2 side is authored twice: the manifest names bytecodes, and every address, the
///         delegate target and the factory-dependency list are functions of them computed here —
///         so there is no redundant field whose consistency would have to be checked.
library L2PlanLib {
    /// @dev The number of bytecodes one deployment installs at most: a system-proxy row carries
    ///      the implementation and the proxy shell.
    uint256 private constant MAX_BYTECODES_PER_DEPLOYMENT = 2;

    /// @notice Builds the final, executable plan: `_derived` first, then the delegate, then the
    ///         extras — every authored bytecode info as an `Unsafe` force deployment at the address
    ///         derived from that info (`keccak256(0x00..00 || info)`, see
    ///         {L2GenesisForceDeploymentsHelper.generateRandomAddress}). `delegateTo` is the
    ///         delegate's derived address (zero without one) and `factoryDepHashes` the observable
    ///         hash of every bytecode any deployment installs, deduplicated in first-occurrence
    ///         order.
    /// @dev Refuses what L2 could not execute: `L2ComplexUpgrader.forceDeployAndUpgradeUniversal`
    ///      unconditionally ends with the delegatecall, so deployments without a delegate would
    ///      construct here and revert on L2 forever; a composer without a delegate would be dead
    ///      payload; and more factory dependencies than `BaseZkSyncUpgrade._verifyFactoryDeps`
    ///      accepts would let `applyCTMUpgrade` bump the CTM and then fail every chain upgrade.
    /// @param _derived The table-derived deployments (see {TransitionDerivationLib}).
    /// @param _authored The manifest's authored L2 input.
    function build(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _derived,
        AuthoredL2Plan memory _authored
    ) internal pure returns (L2UpgradePlan memory plan) {
        bool hasDelegate = _authored.delegateBytecodeInfo.length != 0;
        uint256 derivedLength = _derived.length;
        uint256 extrasLength = _authored.extraBytecodeInfos.length;
        plan.deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](
            derivedLength + (hasDelegate ? 1 : 0) + extrasLength
        );
        for (uint256 i = 0; i < derivedLength; ++i) {
            plan.deployments[i] = _derived[i];
        }
        uint256 cursor = derivedLength;
        if (hasDelegate) {
            plan.deployments[cursor] = _unsafeDeployment(_authored.delegateBytecodeInfo);
            plan.delegateTo = plan.deployments[cursor].newAddress;
            ++cursor;
        }
        for (uint256 i = 0; i < extrasLength; ++i) {
            plan.deployments[cursor] = _unsafeDeployment(_authored.extraBytecodeInfos[i]);
            ++cursor;
        }
        plan.delegateComposer = _authored.delegateComposer;
        plan.factoryDepHashes = _factoryDepHashes(plan.deployments);

        if (!hasDelegate && (plan.deployments.length != 0 || plan.delegateComposer != address(0))) {
            revert MalformedL2UpgradePlan();
        }
        if (plan.factoryDepHashes.length > MAX_NEW_FACTORY_DEPS) {
            revert MalformedL2UpgradePlan();
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

    /// @dev One `Unsafe` force deployment of a canonical bytecode info at its derived address.
    function _unsafeDeployment(
        bytes memory _bytecodeInfo
    ) private pure returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        if (_bytecodeInfo.length != BYTECODE_INFO_LENGTH) {
            revert MalformedL2UpgradePlan();
        }
        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: _bytecodeInfo,
                newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(_bytecodeInfo)
            });
    }

    /// @dev The observable hash of every bytecode `_deployments` install, each once, in
    ///      first-occurrence order: a system-proxy row contributes its implementation and its
    ///      proxy shell (the shell is shared across rows, hence the deduplication), an Unsafe
    ///      deployment its one bytecode.
    function _factoryDepHashes(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) private pure returns (uint256[] memory hashes) {
        uint256 deploymentsLength = _deployments.length;
        uint256[] memory collected = new uint256[](deploymentsLength * MAX_BYTECODES_PER_DEPLOYMENT);
        uint256 count = 0;
        for (uint256 i = 0; i < deploymentsLength; ++i) {
            IComplexUpgrader.UniversalContractUpgradeInfo memory deployment = _deployments[i];
            if (deployment.upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade) {
                (bytes memory implInfo, bytes memory proxyInfo) = abi.decode(
                    deployment.deployedBytecodeInfo,
                    (bytes, bytes)
                );
                count = _appendUnique(collected, count, _observableHash(implInfo));
                count = _appendUnique(collected, count, _observableHash(proxyInfo));
            } else {
                count = _appendUnique(collected, count, _observableHash(deployment.deployedBytecodeInfo));
            }
        }
        hashes = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            hashes[i] = collected[i];
        }
    }

    /// @dev Appends `_hash` to `_collected[0.._count)` unless already present; returns the new count.
    function _appendUnique(uint256[] memory _collected, uint256 _count, bytes32 _hash) private pure returns (uint256) {
        for (uint256 i = 0; i < _count; ++i) {
            if (_collected[i] == uint256(_hash)) {
                return _count;
            }
        }
        _collected[_count] = uint256(_hash);
        return _count + 1;
    }

    /// @dev The `keccak256` of the deployed EVM bytecode a ZKsync OS bytecode info describes —
    ///      the same key `BytecodesSupplier` publishes under and the L2 transaction's factory
    ///      dependencies carry.
    function _observableHash(bytes memory _bytecodeInfo) private pure returns (bytes32 observableBytecodeHash) {
        (, , observableBytecodeHash) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(_bytecodeInfo);
    }
}
