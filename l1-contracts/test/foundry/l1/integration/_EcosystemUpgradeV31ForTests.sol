// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EcosystemUpgrade_v31} from "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";

contract CTMUpgradeV31ForTests is CTMUpgrade_v31 {
    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }
}

contract EcosystemUpgradeV31ForTests is EcosystemUpgrade_v31 {
    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeV31ForTests();
    }
}
