// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade} from "./EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "./ChainUpgrade.s.sol";
import {Call} from "../../contracts/governance/Common.sol";
import {Utils} from "../Utils.sol";
import {IGovernance} from "../../contracts/governance/IGovernance.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Diamond} from "../../contracts/state-transition/libraries/Diamond.sol";

string constant ECOSYSTEM_INPUT = "/upgrade-envs/devnet.toml";
string constant ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/devnet.toml";
string constant CHAIN_INPUT = "/upgrade-envs/devnet-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/devnet-era.toml";

contract UpgradeLocalDevnet is Script, EcosystemUpgrade {
    ChainUpgrade chainUpgrade;

    function run() public override {
        initialize(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);

        chainUpgrade = new ChainUpgrade();

        console.log("Preparing ecosystem upgrade");
        prepareEcosystemUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT, CHAIN_INPUT, CHAIN_OUTPUT);

        (
            Call[] memory upgradeGovernanceStage1Calls,
            Call[] memory upgradeGovernanceStage2Calls
        ) = prepareDefaultGovernanceCalls();

        // Stage 1 is required after Gateway launch
        // console.log("Starting ecosystem upgrade stage 1!");
        // governanceMulticall(getOwnerAddress(), upgradeGovernanceStage1Calls);

        console.log("Starting ecosystem upgrade stage 2!");

        governanceMulticall(getOwnerAddress(), upgradeGovernanceStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        console.log("Upgrading Era");

        // Now, the admin of the Era needs to call the upgrade function.
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutData(getAddresses().stateTransition);
        chainUpgrade.upgradeChain(getOldProtocolVersion(), upgradeCutData);

        // Set timestamp of upgrade for server
        chainUpgrade.setUpgradeTimestamp(getNewProtocolVersion(), block.timestamp + 60);
    }

    function governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable ownable = Ownable(governanceAddr);

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startBroadcast(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        governance.execute{value: 0}(operation);
        vm.stopBroadcast();
    }
}
