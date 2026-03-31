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

    /// @notice Step 1: Deploy core L1 ecosystem contracts only.
    /// @dev Produces ~12 transactions. Call step2() afterward.
    function step1() public {
        initialize(getPermanentValuesInputPath(), getUpgradeInputPath(), getEcosystemOutputPath());
        coreUpgrade.prepareEcosystemUpgrade();
    }

    /// @notice Step 2: Deploy CTM contracts, publish bytecodes, generate governance calls.
    /// @dev Re-initializes from the same config (create2 deploys are idempotent).
    /// Produces ~25 transactions.
    function step2() public {
        initialize(getPermanentValuesInputPath(), getUpgradeInputPath(), getEcosystemOutputPath());
        // Re-run core to populate addresses (all create2 deploys are skipped since already deployed)
        coreUpgrade.prepareEcosystemUpgrade();
        // Now run CTM upgrade + governance calls
        ctmUpgrade.prepareCTMUpgrade();
        saveCombinedOutput();
        prepareDefaultGovernanceCalls();
    }
}
