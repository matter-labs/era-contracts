// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GatewayVotePreparation} from "deploy-scripts/gateway/GatewayVotePreparation.s.sol";

/// @notice Test-only `GatewayVotePreparation` that actually brings a gateway up.
/// @dev The production script refuses to deploy one: this release deploys no gateway, since chain
/// migrations are off ecosystem-wide (see `GatewayVotePreparation.deployGatewayCTM`). The
/// anvil-interop harness still needs a gateway in its fixture — it keeps exercising the gateway
/// machinery the release carries for later versions — so it runs this subclass instead, which calls
/// the deployment the base class keeps but no longer reaches.
contract GatewayVotePreparationForTests is GatewayVotePreparation {
    function deployGatewayCTM() internal override {
        _deployGatewayCTM();
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
