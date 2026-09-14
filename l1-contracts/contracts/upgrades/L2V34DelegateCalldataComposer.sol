// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL2V34Upgrade} from "./IL2V34Upgrade.sol";
import {ZKChainSpecificForceDeploymentsLib} from "./ZKChainSpecificForceDeploymentsLib.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "./registry/objects/IL2DelegateCalldataComposer.sol";

/// @title L2V34DelegateCalldataComposer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The v34 delegate call: `L2V34Upgrade.upgrade` re-initializes the force-deployed system
///         contracts with the release's pinned `FixedForceDeploymentsData`, the ecosystem's live
///         CTM deployment tracker and the chain's own `ZKChainSpecificForceDeploymentsData`.
contract L2V34DelegateCalldataComposer is IL2DelegateCalldataComposer {
    /// @inheritdoc IL2DelegateCalldataComposer
    function composeDelegateCalldata(
        ICTMRelease _newRelease,
        address _bridgehub,
        uint256 _chainId
    ) external view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (
                    address(IBridgehubBase(_bridgehub).l1CtmDeployer()),
                    _newRelease.fixedForceDeploymentsData(),
                    ZKChainSpecificForceDeploymentsLib.build(_bridgehub, _chainId)
                )
            );
    }
}
