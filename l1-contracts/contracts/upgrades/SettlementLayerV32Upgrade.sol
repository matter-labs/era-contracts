// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";
import {UnexpectedZKsyncOSFlag} from "./ZkSyncUpgradeErrors.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @title SettlementLayerV32Upgrade
/// @notice The v32 (atomic interop) upgrade implementation, delegate-called by every chain
///         diamond. v32 is storage-compatible with v31, so unlike the v31 upgrade this contract
///         performs NO L1 storage migration — its only job beyond `BaseZkSyncUpgrade` is
///         injecting the per-chain arguments into the L2 upgrade transaction.
/// @dev The L2 side of the upgrade delegates to the `L2GenesisUpgrade` built-in (at
///      `L2_GENESIS_UPGRADE_ADDR`, force-deployed to its v32 bytecode by the same transaction):
///      the same contract that initializes the L2 system-contract set at chain genesis also
///      (re)initializes the contracts introduced by v32. Its calldata needs `chainId` and
///      chain-specific force-deployment data, which is why the committed (ecosystem-wide)
///      upgrade transaction carries placeholders that this contract rewrites per chain.
/// @dev One contract serves both VMs: from v32 onwards Era and ZKsyncOS both use
///      `ComplexUpgrader.forceDeployAndUpgradeUniversal`.
/// @custom:security-contact security@matterlabs.dev
contract SettlementLayerV32Upgrade is BaseZkSyncUpgrade {
    using Bytes for bytes;

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        proposedUpgrade.l2ProtocolUpgradeTx.data = getL2UpgradeTxData(
            s.bridgehub,
            s.chainId,
            s.zksyncOS,
            proposedUpgrade.l2ProtocolUpgradeTx.data
        );

        super.upgrade(proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Replace the per-chain placeholders in the committed L2 upgrade transaction data.
    /// @dev Public so the server can also call it statically to derive the exact per-chain
    ///      transaction the bootloader will process.
    /// @param _bridgehub The bridgehub address.
    /// @param _chainId The chain the transaction is built for.
    /// @param _zksyncOS Whether the chain is a ZKsyncOS chain.
    /// @param _existingTxData The committed (placeholder) transaction data:
    ///        `forceDeployAndUpgradeUniversal(deployments, L2_GENESIS_UPGRADE_ADDR,
    ///        genesisUpgrade(isZKsyncOS, <placeholder>, ctmDeployer, fixedData, <placeholder>))`.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view returns (bytes memory) {
        L2UpgradeTxLib.validateUpgradeSelector(
            _existingTxData,
            IComplexUpgrader.forceDeployAndUpgradeUniversal.selector
        );

        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments,
            address delegateTo,
            bytes memory existingGenesisUpgradeCalldata
        ) = abi.decode(_existingTxData.slice(4), (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

        L2UpgradeTxLib.validateUpgradeSelector(
            existingGenesisUpgradeCalldata,
            IL2GenesisUpgrade.genesisUpgrade.selector
        );
        // The chainId and additionalForceDeploymentsData placeholders are ignored and rebuilt.
        (bool isZKsyncOS, , address ctmDeployer, bytes memory fixedForceDeploymentsData, ) = abi.decode(
            existingGenesisUpgradeCalldata.slice(4),
            (bool, uint256, address, bytes, bytes)
        );
        if (isZKsyncOS != _zksyncOS) {
            revert UnexpectedZKsyncOSFlag(_zksyncOS, isZKsyncOS);
        }

        bytes memory additionalForceDeploymentsData = L2UpgradeTxLib.buildChainSpecificForceDeploymentsData(
            _bridgehub,
            _chainId
        );

        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (
                    deployments,
                    delegateTo,
                    abi.encodeCall(
                        IL2GenesisUpgrade.genesisUpgrade,
                        (isZKsyncOS, _chainId, ctmDeployer, fixedForceDeploymentsData, additionalForceDeploymentsData)
                    )
                )
            );
    }
}
