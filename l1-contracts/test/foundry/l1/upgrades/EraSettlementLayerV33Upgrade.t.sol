// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EraSettlementLayerV33Upgrade} from "contracts/upgrades/EraSettlementLayerV33Upgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {MustBeEraChain} from "contracts/common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_MASK} from "contracts/common/Config.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyEraSettlementLayerV33Upgrade is EraSettlementLayerV33Upgrade, BaseUpgradeUtils {
    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
    }

    function setDisabledProofSystems(uint8 _mask) public {
        s.disabledProofSystems = _mask;
    }

    function getDisabledProofSystems() public view returns (uint8) {
        return s.disabledProofSystems;
    }

    function setTotalBatchesCommitted(uint256 _n) public {
        s.totalBatchesCommitted = _n;
    }

    function setTotalBatchesExecuted(uint256 _n) public {
        s.totalBatchesExecuted = _n;
    }
}

contract EraSettlementLayerV33UpgradeTest is BaseUpgrade {
    DummyEraSettlementLayerV33Upgrade internal upgradeContract;
    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        upgradeContract = new DummyEraSettlementLayerV33Upgrade();

        _prepareProposedUpgrade();

        upgradeContract.setPriorityTxMaxGasLimit(1 ether);
        upgradeContract.setPriorityTxMaxPubdata(1000000);
        upgradeContract.setChainTypeManager(mockChainTypeManager);
        upgradeContract.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_doesNotTouchTheProofSystemMask() public {
        upgradeContract.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        upgradeContract.upgrade(proposedUpgrade);

        assertEq(upgradeContract.getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    /// A batch committed before the upgrade carries no Airbender commitment and could not be proved.
    function test_revertWhen_batchesStillInFlight() public {
        upgradeContract.setTotalBatchesCommitted(5);
        upgradeContract.setTotalBatchesExecuted(4);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }

    function test_allowsAFullyExecutedPipeline() public {
        upgradeContract.setTotalBatchesCommitted(5);
        upgradeContract.setTotalBatchesExecuted(5);

        assertEq(upgradeContract.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
    }

    function test_stillPerformsTheBaseUpgrade() public {
        upgradeContract.upgrade(proposedUpgrade);

        assertEq(upgradeContract.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(upgradeContract.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    function test_revertWhen_zksyncOSChain() public {
        upgradeContract.setZKsyncOS(true);

        vm.expectRevert(MustBeEraChain.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }
}
