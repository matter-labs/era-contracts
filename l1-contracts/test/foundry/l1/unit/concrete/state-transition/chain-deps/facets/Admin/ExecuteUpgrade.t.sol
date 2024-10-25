// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "../../../../Utils/Utils.sol";

import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

contract ExecuteUpgradeTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function test_revertWhen_calledByNonGovernorOrChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        vm.startPrank(nonChainTypeManager);
        adminFacet.executeUpgrade(diamondCutData);
    }

    /// TODO: This test should be removed after the migration to the semver is complete everywhere.
    function test_migrateToSemVerApproach() public {
        // Setting minor protocol version manually
        utilsFacet.util_setProtocolVersion(22);

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: bytes32(0),
            recursionLeafLevelVkHash: bytes32(0),
            recursionCircuitsSetVksHash: bytes32(0)
        });

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            verifier: address(0),
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: SemVer.packSemVer(0, 22, 0)
        });

        DefaultUpgrade upgrade = new DefaultUpgrade();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(upgrade),
            initCalldata: abi.encodeCall(upgrade.upgrade, (proposedUpgrade))
        });

        address ctm = utilsFacet.util_getChainTypeManager();
        vm.startPrank(ctm);

        adminFacet.executeUpgrade(diamondCutData);
    }
}

interface IDiamondLibrary {
    function diamondCut(Diamond.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) external;
}
