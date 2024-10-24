// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {EcosystemUpgrade} from "deploy-scripts/upgrade/EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";

string constant ECOSYSTEM_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet.toml";
string constant ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet.toml";
string constant CHAIN_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet-era.toml";

contract UpgradeTest is Test {
    EcosystemUpgrade generateUpgradeData;
    ChainUpgrade chainUpgrade;

    function setUp() public {
        generateUpgradeData = new EcosystemUpgrade();
        chainUpgrade = new ChainUpgrade();
    }

    function test_MainnetFork() public {
        console.log("Preparing ecosystem contracts");
        // Firstly, we deploy all the contracts.
        generateUpgradeData.prepareEcosystemContracts(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);

        // For chain, we have deployed the DA validator contracts
        // and also updated the chain admin.
        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT, CHAIN_INPUT, CHAIN_OUTPUT);

        console.log("Starting stage1 of the upgrade!");
        // Now, some time has passed and we are ready to start the upgrade of the
        // ecosystem.
        Call[] memory stage1Calls = generateUpgradeData.getStage1UpgradeCalls();

        governanceMulticall(generateUpgradeData.getOwnerAddress(), stage1Calls);

        console.log("Stage1 is done, now all the chains have to upgrade to the new version");

        console.log("Upgrading Era");

        // Now, the admin of the Era needs to call the upgrade function.
        // Note, that the step below also updated ValidatorTimelock so the server needs to be ready for that.
        // TODO: We do not include calls that ensure that the server is ready for the sake of brevity.
        chainUpgrade.upgradeChain(
            generateUpgradeData.getOldProtocolVersion(),
            generateUpgradeData.getChainUpgradeInfo()
        );

        // TODO: here we should include tests that depoists work for upgraded chains
        // including era specific deposit/withdraw functions
        // We also may need to test that normal flow of block commit / verify / execute works (but it is hard)
        // so it was tested in e2e local environment.

        console.log("Starting stage2 of the upgrade!");
        governanceMulticall(generateUpgradeData.getOwnerAddress(), generateUpgradeData.getStage2UpgradeCalls());

        // TODO: here we should have tests that the bridging works for the previously deployed chains
        // and that it does not work for those that did not upgrade.
        // TODO: test that creation of new chains works under new conditions.
        // TODO: if not hard, include test for deploying a gateway and migrating Era to it.
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
