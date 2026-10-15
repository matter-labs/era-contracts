// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";
import {NotMultiProofMode} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeUtils {}

contract DefaultUpgradeTest is BaseUpgrade {
    DummyDefaultUpgrade internal baseZkSyncUpgrade;
    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        baseZkSyncUpgrade = new DummyDefaultUpgrade();

        _prepareProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);

        // Set up CTM for verifier lookup
        baseZkSyncUpgrade.setChainTypeManager(mockChainTypeManager);
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_SuccessUpgrade() public {
        bytes32 result = baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    /// @notice The second-proof-system lock also applies to the verifier-only upgrade.
    /// See {protocol-docs/interop-gating.md#second-proof-system-lock}.
    function test_revertWhen_LockedChainRunsVerifierOnlyUpgradeToSingleProofVerifier() public {
        address singleProofVerifier = address(new ZKsyncOSVerifier(IVerifier(makeAddr("airbenderPlonk"))));
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, singleProofVerifier);
        baseZkSyncUpgrade.setSecondProofSystemLocked(true);

        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        baseZkSyncUpgrade.upgradeVerifierOnly(protocolVersion);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), 0);
        assertEq(baseZkSyncUpgrade.getVerifier(), address(0));
    }

    function test_LockedChainRunsVerifierOnlyUpgradeToMultiProofVerifier() public {
        address multiProofVerifier = address(
            new MultiProofVerifier(IVerifier(makeAddr("airbenderVerifier")), IVerifier(makeAddr("ziskVerifier")))
        );
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, multiProofVerifier);
        baseZkSyncUpgrade.setSecondProofSystemLocked(true);

        bytes32 result = baseZkSyncUpgrade.upgradeVerifierOnly(protocolVersion);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(baseZkSyncUpgrade.getVerifier(), multiProofVerifier);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }
}
