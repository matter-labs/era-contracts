// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgrade} from "./DefaultUpgrade.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ZKsyncOSSettlementLayerV32Upgrade
/// @notice Per-chain upgrade for ZKsync OS chains moving from v31 onto this release.
/// @dev The plain {DefaultUpgrade} is all this release needs on L1, except for one thing: the CTM upgrade
/// emits a single ecosystem-wide L2 upgrade transaction, whose inner `IL2V31Upgrade.upgrade` calldata
/// carries a placeholder for the chain-specific force-deployments data. Substituting the real per-chain
/// data can only happen here, where the chain is known. Unlike {SettlementLayerV31UpgradeBase} this does
/// none of v31's one-time work — a chain arriving here has already been through v31, so
/// `saveV31UpgradeChainBatchNumber` would revert and resetting the DA validators would drop configuration
/// the chain has set since.
contract ZKsyncOSSettlementLayerV32Upgrade is DefaultUpgrade {
    using Bytes for bytes;

    /// @inheritdoc DefaultUpgrade
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        // Rewritten in place: `_proposedUpgrade` is a memory reference, and the base implementation must
        // see the per-chain data, not the placeholder it was called with.
        _proposedUpgrade.l2ProtocolUpgradeTx.data = getL2UpgradeTxData(
            s.bridgehub,
            s.chainId,
            s.zksyncOS,
            _proposedUpgrade.l2ProtocolUpgradeTx.data
        );

        return super.upgrade(_proposedUpgrade);
    }

    /// @notice Rewrite the ecosystem-wide L2 upgrade tx data for this chain.
    /// @dev Also called directly by the server, hence `public` and free of diamond-storage reads.
    /// @param _bridgehub The bridgehub of the ecosystem.
    /// @param _chainId The chain being upgraded.
    /// @param _zksyncOS Whether the chain runs ZKsync OS, taken from diamond storage by the caller.
    /// @param _existingTxData The L2 upgrade tx data the CTM upgrade produced.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view returns (bytes memory) {
        L2UpgradeTxLib.validateZKsyncOSFlag(_zksyncOS, true);
        L2UpgradeTxLib.validateUpgradeSelector(
            _existingTxData,
            IComplexUpgrader.forceDeployAndUpgradeUniversal.selector
        );

        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory forceDeployments,
            address delegateTo,
            bytes memory existingUpgradeCalldata
        ) = abi.decode(_existingTxData.slice(4), (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

        L2UpgradeTxLib.validateWrappedUpgrade(existingUpgradeCalldata);
        bytes memory l2UpgradeCalldata = L2UpgradeTxLib.buildL2V31UpgradeCalldata(
            _bridgehub,
            _chainId,
            _zksyncOS,
            existingUpgradeCalldata
        );

        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (forceDeployments, delegateTo, l2UpgradeCalldata)
            );
    }
}
