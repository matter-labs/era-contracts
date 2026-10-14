// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice Prepares the v35 upgrade: the default upgrade, plus the `L1InteropFeeManager` proxy the new CTM is
/// constructed with. See {protocol-docs/interop-fee.md#the-switch}.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v35 is DefaultCTMUpgrade {
    /// @inheritdoc DefaultCTMUpgrade
    /// @dev A CTM already on v35 (a patch upgrade, or `UpgradeTest_Local`'s fixture) keeps its manager.
    function deployNewCTMContracts() public override {
        if (ctmAddresses.stateTransition.proxies.interopFeeManager == address(0)) {
            (
                ctmAddresses.stateTransition.implementations.interopFeeManager,
                ctmAddresses.stateTransition.proxies.interopFeeManager
            ) = deployTuppWithContract("L1InteropFeeManager");
        }
        super.deployNewCTMContracts();
    }
}
