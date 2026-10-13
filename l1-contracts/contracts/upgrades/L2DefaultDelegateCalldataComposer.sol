// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL2DefaultUpgrade} from "./IL2DefaultUpgrade.sol";
import {ZKChainSpecificForceDeploymentsLib} from "./ZKChainSpecificForceDeploymentsLib.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "./registry/objects/IL2DelegateCalldataComposer.sol";

/// @title L2DefaultDelegateCalldataComposer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The delegate call of every release: `L2DefaultUpgrade.upgrade` re-initializes the
///         force-deployed system contracts with the release's pinned `FixedForceDeploymentsData`, the ecosystem's live
///         CTM deployment tracker and the chain's own `ZKChainSpecificForceDeploymentsData`.
contract L2DefaultDelegateCalldataComposer is IL2DelegateCalldataComposer {
    /// @inheritdoc IL2DelegateCalldataComposer
    function composeDelegateCalldata(
        ICTMRelease _newRelease,
        address _bridgehub,
        uint256 _chainId
    ) external view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2DefaultUpgrade.upgrade,
                (
                    address(IBridgehubBase(_bridgehub).l1CtmDeployer()),
                    _newRelease.fixedForceDeploymentsData(),
                    ZKChainSpecificForceDeploymentsLib.build(_bridgehub, _chainId)
                )
            );
    }
}
