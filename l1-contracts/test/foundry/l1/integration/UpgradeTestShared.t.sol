// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultCTMUpgrade.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

contract UpgradeIntegrationTestBase is Test {
    EcosystemUpgrade_v31 ecosystemUpgrade;
    DefaultCTMUpgrade ctmUpgrade;
    DefaultChainUpgrade chainUpgrade;

    // For now, this test is testing "stage" - as mainnet wasn't updated yet.
    string public ECOSYSTEM_INPUT;
    string public ECOSYSTEM_UPGRADE_INPUT;
    string public PERMANENT_VALUES_INPUT;
    string public ECOSYSTEM_OUTPUT;
    string public CTM_INPUT;
    string public CTM_OUTPUT;
    string public CHAIN_INPUT;
    string public CHAIN_OUTPUT;

    function setupUpgrade() public {
        ecosystemUpgrade = new EcosystemUpgrade_v31();
        ecosystemUpgrade.initialize(PERMANENT_VALUES_INPUT, ECOSYSTEM_UPGRADE_INPUT, ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);
        ecosystemUpgrade.deployNewEcosystemContractsL1();
        chainUpgrade = new DefaultChainUpgrade();
        ctmUpgrade = new DefaultCTMUpgrade();
        // ctmUpgrade.initialize(PERMANENT_VALUES_INPUT, CTM_INPUT, CTM_OUTPUT);
    }

    function internalTest() internal {
        console.log("Preparing ecosystem upgrade");
        ecosystemUpgrade.prepareEcosystemUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(PERMANENT_VALUES_INPUT, CHAIN_INPUT);

        (
            Call[] memory upgradeGovernanceStage0Calls,
            Call[] memory upgradeGovernanceStage1Calls,
            Call[] memory upgradeGovernanceStage2Calls
        ) = ecosystemUpgrade.prepareDefaultGovernanceCalls();

        // ecosystemUpgrade.setOwners(IOwnable(ecosystemUpgrade.getDiscoveredBridgehub().chainAssetHandler).owner());

        console.log("Starting ecosystem upgrade stage 0!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage0Calls);

        // console.log("proxy admin owner", IOwnable(ecosystemUpgrade.getDiscoveredBridgehub().transparentProxyAdmin).owner());

        console.log("Starting ecosystem upgrade stage 1!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage1Calls);

        console.log("Starting ecosystem upgrade stage 2!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        console.log("Upgrading gateway");

        // Now, the admin of the Era needs to call the upgrade function.
        // TODO: We do not include calls that ensure that the server is ready for the sake of brevity.
        // chainUpgrade.upgradeChain(
        //     ctmUpgrade.getOldProtocolVersion(),
        //     ctmUpgrade.generateUpgradeCutDataFromLocalConfig(ctmUpgrade.getAddresses().stateTransition)
        // );

        // console.log("Creating new chain");
        // address admin = ctmUpgrade.getBridgehubAdmin();
        // vm.startPrank(admin);
        // Call memory createNewChainCall = ctmUpgrade.prepareCreateNewChainCall(555)[0];
        // (bool success, bytes memory data) = payable(createNewChainCall.target).call{value: createNewChainCall.value}(
        //     createNewChainCall.data
        // );
        // require(success, "Create new chain call failed");
        // vm.stopPrank();

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
