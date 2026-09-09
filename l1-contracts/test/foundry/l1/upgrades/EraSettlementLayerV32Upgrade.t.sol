// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EraSettlementLayerV32Upgrade} from "contracts/upgrades/EraSettlementLayerV32Upgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";
import {MustBeEraChain} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyEraSettlementLayerV32Upgrade is EraSettlementLayerV32Upgrade, BaseUpgradeUtils {
    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
    }

    function getDisabledProofSystems() public view returns (uint8) {
        return s.disabledProofSystems;
    }
}

/// @notice The v32 upgrade must leave an Era chain single-proof.
/// @dev The upgrade installs the multi-proof gate, and `disabledProofSystems` is new in this version,
/// so it reads zero on a chain arriving here — which requires both systems. Batches committed before
/// the cut carry no Airbender commitment and the gate would refuse them, while `Committer` would
/// start demanding a heap hash the sequencer is not sending. The mask has to be set by the same
/// initializer that installs the facets, which is why it does not live in the v31 upgrade: the v32
/// path deploys `DefaultUpgrade`, and that historical initializer never runs on it.
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

    function test_masksTheAirbenderLane() public {
        // Pre-upgrade storage: the field is unused before the gate exists, so the upgrade must not
        // rely on finding it already set.
        assertEq(upgradeContract.getDisabledProofSystems(), 0);

        bytes32 result = upgradeContract.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(
            upgradeContract.getDisabledProofSystems(),
            AIRBENDER_PROOF_SYSTEM_DISABLED,
            "a chain must come out of the upgrade with the Airbender lane masked"
        );
    }

    /// The rest of the upgrade still has to happen, so the mask is not being set by a stub.
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
