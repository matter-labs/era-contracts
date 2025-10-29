// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {EcosystemUpgrade_v29} from "deploy-scripts/upgrade/EcosystemUpgrade_v29.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";

// For now, this test is testing "stage" - as mainnet wasn't updated yet.
string constant ECOSYSTEM_INPUT = "/upgrade-envs/v0.28.0-precompiles/stage.toml";
string constant ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage.toml";
string constant CHAIN_INPUT = "/upgrade-envs/v0.28.0-precompiles/stage-gateway.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage-gateway.toml";

contract UpgradeIntegrationTest is Test {
    EcosystemUpgrade_v29 ecosystemUpgrade;
    ChainUpgrade chainUpgrade;

    function setUp() public {
        ecosystemUpgrade = new EcosystemUpgrade_v29();
        ecosystemUpgrade.initialize(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);

        chainUpgrade = new ChainUpgrade();
    }

    // NOTE: this test is currently testing "stage" - as mainnet is not upgraded yet.
    function test_MainnetFork() public {
        console.log("Preparing ecosystem upgrade");
        ecosystemUpgrade.prepareEcosystemUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT, CHAIN_INPUT, CHAIN_OUTPUT);

        (
            Call[] memory upgradeGovernanceStage0Calls,
            Call[] memory upgradeGovernanceStage1Calls,
            Call[] memory upgradeGovernanceStage2Calls
        ) = ecosystemUpgrade.prepareDefaultGovernanceCalls();

        console.log("Starting ecosystem upgrade stage 0!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage0Calls);

        console.log("Starting ecosystem upgrade stage 1!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage1Calls);

        console.log("Starting ecosystem upgrade stage 2!");

        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        console.log("Upgrading gateway");

        // Now, the admin of the Era needs to call the upgrade function.
        // TODO: We do not include calls that ensure that the server is ready for the sake of brevity.
        chainUpgrade.upgradeChain(
            ecosystemUpgrade.getOldProtocolVersion(),
            ecosystemUpgrade.generateUpgradeCutData(ecosystemUpgrade.getAddresses().stateTransition)
        );

        console.log("Creating new chain");
        address admin = ecosystemUpgrade.getBridgehubAdmin();
        vm.startPrank(admin);
        Call memory createNewChainCall = ecosystemUpgrade.prepareCreateNewChainCall(555)[0];
        (bool success, bytes memory data) = payable(createNewChainCall.target).call{value: createNewChainCall.value}(
            createNewChainCall.data
        );
        require(success, "Create new chain call failed");
        vm.stopPrank();

        // TODO: here we should include tests that depoists work for upgraded chains
        // including era specific deposit/withdraw functions
        // We also may need to test that normal flow of block commit / verify / execute works (but it is hard)
        // so it was tested in e2e local environment.
    }

    /// @dev This is a contract that is used for additional visibility of transactions
    /// that the decentralized governance should do.
    function governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        // How the governance is implemented is out of scope here
        vm.startBroadcast(governanceAddr);

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

            (bool success, bytes memory data) = payable(call.target).call{value: call.value}(call.data);
            require(success, "Multicall failed");
        }

        vm.stopBroadcast();
    }
}
