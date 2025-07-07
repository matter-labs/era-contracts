// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade} from "./EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "./ChainUpgrade.s.sol";
import {Call} from "../../contracts/governance/Common.sol";
import {Utils} from "../Utils.sol";
import {IGovernance} from "../../contracts/governance/IGovernance.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Diamond} from "../../contracts/state-transition/libraries/Diamond.sol";
import {IZKChain} from "../../contracts/state-transition/chain-interfaces/IZKChain.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "../../contracts/upgrades/BaseZkSyncUpgrade.sol";
import {SemVer} from "../../contracts/common/libraries/SemVer.sol";
import {VerifierParams} from "../../contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FacetCut} from "deploy-scripts/Utils.sol";
import {DefaultUpgrade} from "../../contracts/upgrades/DefaultUpgrade.sol";
import {IChainAdminOwnable} from "../../contracts/governance/IChainAdminOwnable.sol";
import {IAdmin} from "../../contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Bridgehub} from "../../contracts/bridgehub/Bridgehub.sol";



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
            Call[] memory upgradeGovernanceStage0Calls,
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

    function upgradeVerifier(address bridgehubAddr, uint256 chainId, address defaultUpgrade, address create2FactoryAddr) public {
        console.logAddress(create2FactoryAddr);
        instantiateCreate2Factory();
//        _initCreate2FactoryParams(create2FactoryAddr, bytes32(0));

        address verifier = deploySimpleContract("VerifierPlonk", false);
        // TODO switch to another verifier
//        address verifierFflonk = deploy - scriptsySimpleContract("VerifierFflonk", false);
//        address verifier = deploySimpleContract("Verifier", false);

        console.log("Verifier address: %s", verifier);
        Bridgehub bridgehub = Bridgehub(bridgehubAddr);
        IZKChain diamondProxy = IZKChain(bridgehub.getZKChain(chainId));

        console.log("Diamond proxy address: %s", address(diamondProxy));
        (uint32 major, uint32 minor, uint32 patch) = diamondProxy.getSemverProtocolVersion();
        console.log("Current protocol version: %s.%s.%s", major, minor, patch);
        uint256 oldVerion = SemVer.packSemVer(major, minor, patch);
        uint256 newVersion = SemVer.packSemVer(major, minor, patch + 1);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeEmptyUpgradeTx(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: verifier,
            verifierParams: VerifierParams({
            recursionNodeLevelVkHash: bytes32(0),
            recursionLeafLevelVkHash: bytes32(0),
            recursionCircuitsSetVksHash: bytes32(0)
        }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: newVersion
        });

        Diamond.DiamondCutData memory upgradeCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });

        address admin = diamondProxy.getAdmin();
        console.log("Admin address: %s", admin);
        Utils.adminExecute(
            admin,
            address(0),
            address(diamondProxy),
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldVerion, upgradeCutData)),
            0
        );

//        address adminOwner = Ownable(admin).owner();
//
//        vm.startBroadcast(adminOwner);
//        IChainAdminOwnable(admin).setUpgradeTimestamp(newVersion, block.timestamp);

    }
}
