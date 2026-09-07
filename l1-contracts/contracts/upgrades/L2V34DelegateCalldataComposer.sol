// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL2V34Upgrade} from "./IL2V34Upgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "./registry/objects/IL2DelegateCalldataComposer.sol";

/// @title L2V34DelegateCalldataComposer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The v34 delegate call: `L2V34Upgrade.upgrade` re-initializes the force-deployed system
///         contracts with the release's pinned `FixedForceDeploymentsData` and the ecosystem's
///         live CTM deployment tracker. The per-chain `ZKChainSpecificForceDeploymentsData` stays
///         empty here and is filled in by the ZKsync OS upgrade engine on each chain.
/// @dev The repository is ZKsync-OS-only, so the VM flag is fixed.
contract L2V34DelegateCalldataComposer is IL2DelegateCalldataComposer {
    /// @inheritdoc IL2DelegateCalldataComposer
    function composeDelegateCalldata(ICTMRelease _newRelease, address _bridgehub) external view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (true, address(IBridgehubBase(_bridgehub).l1CtmDeployer()), _newRelease.fixedForceDeploymentsData(), "")
            );
    }
}
