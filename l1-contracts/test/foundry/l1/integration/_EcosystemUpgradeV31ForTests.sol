// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EcosystemUpgrade_v31} from "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {CoreUpgrade_v31} from "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";

contract CTMUpgradeV31ForTests is CTMUpgrade_v31 {
    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }
}

/// @dev CoreUpgrade that skips updateContractConnections() on re-run.
/// Used in step2() where we only need to re-populate deployed addresses
/// (create2 deploys are idempotent) without re-running side effects
/// like setAddresses() and transferOwnership() that already happened in step1().
contract CoreUpgradeV31Idempotent is CoreUpgrade_v31 {
    function deployNewEcosystemContractsL1() public virtual override {
        super.deployNewEcosystemContractsL1NoConnections();
    }
}

contract EcosystemUpgradeV31ForTests is EcosystemUpgrade_v31 {
    bool private _useIdempotentCore;

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeV31ForTests();
    }

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        if (_useIdempotentCore) {
            return new CoreUpgradeV31Idempotent();
        }
        return new CoreUpgrade_v31();
    }

    /// @notice Step 1: Deploy core L1 ecosystem contracts + configure connections.
    /// @dev Produces ~12 transactions. Call step2() afterward.
    function step1() public {
        initialize(getPermanentValuesInputPath(), getUpgradeInputPath(), getEcosystemOutputPath());
        coreUpgrade.prepareEcosystemUpgrade();
    }

    /// @notice Step 2: Re-populate core addresses (idempotent), deploy CTM, generate governance calls.
    /// @dev Uses CoreUpgradeV31Idempotent to skip setAddresses/transferOwnership side effects.
    /// Produces ~25 transactions.
    function step2() public {
        _useIdempotentCore = true;
        initialize(getPermanentValuesInputPath(), getUpgradeInputPath(), getEcosystemOutputPath());
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }
}
