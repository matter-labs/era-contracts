// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EraSettlementLayerV32Upgrade} from "contracts/upgrades/EraSettlementLayerV32Upgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {MustBeEraChain} from "contracts/common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyEraSettlementLayerV32Upgrade is EraSettlementLayerV32Upgrade, BaseUpgradeUtils {
    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
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

/// @notice The v32 upgrade installs the multi-proof gate, so the chain requires both systems from
/// the cut onwards.
/// @dev `disabledProofSystems` is new in this version and reads zero, which requires both. A batch
/// committed before the cut carries no Airbender commitment and the gate would refuse it, so the
/// upgrade refuses to run with any in flight — the same rule the v31 upgrade applies.
contract EraSettlementLayerV32UpgradeTest is BaseUpgrade {
    DummyEraSettlementLayerV32Upgrade internal upgradeContract;
    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        upgradeContract = new DummyEraSettlementLayerV32Upgrade();

        _prepareProposedUpgrade();

        upgradeContract.setPriorityTxMaxGasLimit(1 ether);
        upgradeContract.setPriorityTxMaxPubdata(1000000);
        upgradeContract.setChainTypeManager(mockChainTypeManager);
        upgradeContract.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_leavesBothProofSystemsRequired() public {
        upgradeContract.upgrade(proposedUpgrade);

        assertEq(
            upgradeContract.getDisabledProofSystems(),
            0,
            "the chain must come out of the upgrade requiring both proof systems"
        );
    }

    /// A batch committed but not executed carries no Airbender commitment, and the gate installed by
    /// this cut would refuse it. The upgrade refuses to run rather than strand it.
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

    /// The rest of the upgrade still has to happen, so the guard is not short-circuiting it.
    function test_stillPerformsTheBaseUpgrade() public {
        upgradeContract.upgrade(proposedUpgrade);

        assertEq(upgradeContract.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(upgradeContract.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    /// ZKsync OS chains have no Airbender lane to mask and never run the Era gate, so routing one
    /// through this initializer is a wiring mistake rather than something to silently absorb.
    function test_revertWhen_zksyncOSChain() public {
        upgradeContract.setZKsyncOS(true);

        vm.expectRevert(MustBeEraChain.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }
}
