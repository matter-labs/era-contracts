// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {
    ProofSystem,
    ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE
} from "contracts/common/Config.sol";
import {NotMultiProofMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {SecondProofSystemAlreadyLocked} from "contracts/state-transition/L1StateTransitionErrors.sol";

import {InteropGatingDeployer} from "../_SharedInteropGatingDeployer.t.sol";

/// @notice A diamond-cut initializer that replaces the verifier without the check of `BaseZkSyncUpgrade._setVerifier`,
/// standing in for an upgrade that forgets it.
contract VerifierOverwrite is ZKChainBase {
    function overwriteVerifier(IVerifier _verifier) external returns (bytes32) {
        s.verifier = _verifier;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

/// @notice The permanent second-proof-system lock and the ZiSK switch auth it changes. See
/// {protocol-docs/interop-gating.md#second-proof-system-lock}.
contract SecondProofSystemLockTest is InteropGatingDeployer {
    uint8 internal constant ZISK_DISABLED = uint8(1 << uint8(ProofSystem.Zisk));

    address internal chain;
    address internal chainAdmin;
    address internal governance;

    function setUp() public {
        _deployInteropGatingEcosystem();
        chain = getZKChainAddress(zkChainIds[0]);
        governance = addresses.bridgehubOwnerAddress;
        // The harness gives the chain the Bridgehub owner as its admin; the auth split needs them apart.
        chainAdmin = makeAddr("chainAdmin");
        vm.prank(IGetters(chain).getAdmin());
        IAdmin(chain).setPendingAdmin(chainAdmin);
        vm.prank(chainAdmin);
        IAdmin(chain).acceptAdmin();
        assertNotEq(chainAdmin, governance);
    }

    function test_lockSecondProofSystem() public {
        assertFalse(IGetters(chain).isSecondProofSystemLocked());

        vm.expectEmit(true, true, true, true, chain);
        emit IAdmin.SecondProofSystemLocked();
        vm.prank(chainAdmin);
        IAdmin(chain).lockSecondProofSystem();

        assertTrue(IGetters(chain).isSecondProofSystemLocked());
        assertEq(IGetters(chain).getProofMode(), ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE);
    }

    function test_lockSecondProofSystem_revertWhen_alreadyLocked() public {
        _lock();

        vm.prank(chainAdmin);
        vm.expectRevert(SecondProofSystemAlreadyLocked.selector);
        IAdmin(chain).lockSecondProofSystem();

        assertTrue(IGetters(chain).isSecondProofSystemLocked());
    }

    function test_lockSecondProofSystem_revertWhen_ziskDisabled() public {
        _setZiskStatus(chainAdmin, false);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        IAdmin(chain).lockSecondProofSystem();

        assertFalse(IGetters(chain).isSecondProofSystemLocked());
    }

    function test_lockSecondProofSystem_revertWhen_notAdmin() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        IAdmin(chain).lockSecondProofSystem();

        assertFalse(IGetters(chain).isSecondProofSystemLocked());
    }

    /// @notice Before the lock, only the chain admin switches ZiSK, in both directions.
    function test_beforeLock_adminSwitchesZisk() public {
        _setZiskStatus(chainAdmin, false);
        _setZiskStatus(chainAdmin, true);
    }

    function test_beforeLock_revertWhen_governanceDisablesZisk() public {
        _expectUnauthorizedZiskSwitch(governance, false);
    }

    function test_afterLock_revertWhen_adminDisablesZisk() public {
        _lock();
        _expectUnauthorizedZiskSwitch(chainAdmin, false);
    }

    /// @notice The emergency switch: governance disables ZiSK on a locked chain, which stays locked; the chain
    /// admin can turn it back on.
    function test_afterLock_governanceDisablesAndAdminReenablesZisk() public {
        _lock();

        _setZiskStatus(governance, false);
        assertEq(IGetters(chain).getProofMode(), ZKSYNC_OS_PLONK_VERIFICATION_TYPE);
        assertTrue(IGetters(chain).isSecondProofSystemLocked());

        _setZiskStatus(chainAdmin, true);
        assertEq(IGetters(chain).getProofMode(), ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE);
    }

    function test_afterLock_revertWhen_governanceEnablesZisk() public {
        _lock();
        _setZiskStatus(governance, false);
        _expectUnauthorizedZiskSwitch(governance, true);
    }

    /// @notice The Admin facet refuses any diamond cut that leaves a locked chain on a verifier without the
    /// multi-proof mode, here one the chain type manager's owner executes.
    function test_afterLock_revertWhen_upgradeSetsSingleProofVerifier() public {
        _lock();
        address verifierBefore = IGetters(chain).getVerifier();
        Diamond.DiamondCutData memory cut = _verifierOverwrite(
            address(new ZKsyncOSVerifier(IVerifier(makeAddr("airbenderPlonk"))))
        );

        vm.prank(_ctmOwner());
        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        addresses.chainTypeManager.executeUpgrade(zkChainIds[0], cut);

        assertEq(IGetters(chain).getVerifier(), verifierBefore);
    }

    /// @notice The check reads what the verifier supports, not the chain's flags: a locked chain whose ZiSK
    /// governance switched off still upgrades to a multi-proof verifier.
    function test_afterLock_upgradeSetsMultiProofVerifier() public {
        _lock();
        _setZiskStatus(governance, false);
        address newVerifier = address(
            new MultiProofVerifier(IVerifier(makeAddr("airbenderVerifier")), IVerifier(makeAddr("ziskVerifier")))
        );
        Diamond.DiamondCutData memory cut = _verifierOverwrite(newVerifier);

        vm.prank(_ctmOwner());
        addresses.chainTypeManager.executeUpgrade(zkChainIds[0], cut);

        assertEq(IGetters(chain).getVerifier(), newVerifier);
    }

    function test_beforeLock_upgradeSetsSingleProofVerifier() public {
        address newVerifier = address(new ZKsyncOSVerifier(IVerifier(makeAddr("airbenderPlonk"))));
        Diamond.DiamondCutData memory cut = _verifierOverwrite(newVerifier);

        vm.prank(_ctmOwner());
        addresses.chainTypeManager.executeUpgrade(zkChainIds[0], cut);

        assertEq(IGetters(chain).getVerifier(), newVerifier);
    }

    function _verifierOverwrite(address _verifier) internal returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: address(new VerifierOverwrite()),
                initCalldata: abi.encodeCall(VerifierOverwrite.overwriteVerifier, (IVerifier(_verifier)))
            });
    }

    function _ctmOwner() internal view returns (address) {
        return IOwnable(address(addresses.chainTypeManager)).owner();
    }

    function _lock() internal {
        vm.prank(chainAdmin);
        IAdmin(chain).lockSecondProofSystem();
    }

    function _setZiskStatus(address _caller, bool _enabled) internal {
        uint8 oldMask = IGetters(chain).disabledProofSystems().zisk ? ZISK_DISABLED : 0;
        vm.expectEmit(true, true, true, true, chain);
        emit IAdmin.NewDisabledProofSystems(oldMask, _enabled ? 0 : ZISK_DISABLED);
        vm.prank(_caller);
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, _enabled);
        assertEq(IGetters(chain).disabledProofSystems().zisk, !_enabled);
    }

    function _expectUnauthorizedZiskSwitch(address _caller, bool _enabled) internal {
        bool disabledBefore = IGetters(chain).disabledProofSystems().zisk;
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, _enabled);
        assertEq(IGetters(chain).disabledProofSystems().zisk, disabledBefore);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
