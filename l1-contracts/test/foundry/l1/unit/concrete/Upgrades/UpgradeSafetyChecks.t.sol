// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {UpgradeSafetyChecks} from "deploy-scripts/upgrade/default-upgrade/UpgradeSafetyChecks.sol";
import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

/// @dev The library is `internal`; this harness is the only way to call it from a test.
contract UpgradeSafetyChecksHarness {
    function requireValidatorTimelockAtVersion2(address _proxy) external view {
        UpgradeSafetyChecks.requireValidatorTimelockAtVersion2(_proxy);
    }

    function requireCoreUpgradeTargetHasNoLegacyChains(address _bridgehub) external view {
        UpgradeSafetyChecks.requireCoreUpgradeTargetHasNoLegacyChains(_bridgehub);
    }
}

/// @notice The checks the upgrade prepares run against live state. See
/// {docs/registry-driven-upgrades.md#preconditions-checked-against-live-state}.
/// @dev The timelock cases use real proxies. The bridgehub cases mock the bridgehub, its chain type managers and
///      its chains: the check reads nothing else of them.
contract UpgradeSafetyChecksTest is Test {
    UpgradeSafetyChecksHarness internal checks;
    address internal dummyBridgehub;

    address internal bridgehub = makeAddr("bridgehub");
    address internal zksyncOSCTM = makeAddr("zksyncOSCTM");
    address internal eraCTM = makeAddr("eraCTM");

    function setUp() public {
        checks = new UpgradeSafetyChecksHarness();
        dummyBridgehub = address(new DummyBridgehub());
        vm.mockCall(zksyncOSCTM, abi.encodeCall(IChainTypeManager.isZKsyncOS, ()), abi.encode(true));
        vm.mockCall(eraCTM, abi.encodeCall(IChainTypeManager.isZKsyncOS, ()), abi.encode(false));
    }

    // ─────────────────────────── validator timelock ───────────────────────────

    function test_validatorTimelockAtVersion2_passes() public {
        address proxy = address(
            new TransparentUpgradeableProxy(
                address(new MultisigCommitter(dummyBridgehub)),
                address(new ProxyAdmin()),
                abi.encodeCall(MultisigCommitter.initializeV2, (makeAddr("owner"), 0))
            )
        );

        checks.requireValidatorTimelockAtVersion2(proxy);
    }

    function test_revertWhen_validatorTimelockIsAtVersion1() public {
        address proxy = address(
            new TransparentUpgradeableProxy(
                address(new ValidatorTimelock(dummyBridgehub)),
                address(new ProxyAdmin()),
                abi.encodeCall(ValidatorTimelock.initialize, (makeAddr("owner"), 0))
            )
        );

        vm.expectRevert(
            bytes(
                string.concat(
                    "validator timelock ",
                    vm.toString(proxy),
                    " is below initializer version 2: move it with upgradeAndCall(MultisigCommitter, reinitializeV2) first"
                )
            )
        );
        checks.requireValidatorTimelockAtVersion2(proxy);
    }

    // ─────────────────────────── core upgrade target ───────────────────────────

    function _registerChain(uint256 _chainId, address _ctm, uint256 _protocolVersion) internal {
        address chain = makeAddr(string.concat("chain", vm.toString(_chainId)));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.chainTypeManager, (_chainId)), abi.encode(_ctm));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (_chainId)), abi.encode(chain));
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(_protocolVersion));
    }

    function _setChainIds(uint256[] memory _chainIds) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(_chainIds));
    }

    function test_coreUpgradeTarget_withOnlyZKsyncOSChainsAtV33OrLater_passes() public {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 5790;
        chainIds[1] = 51703;
        _setChainIds(chainIds);
        _registerChain(5790, zksyncOSCTM, SemVer.packSemVer(0, 33, 2));
        _registerChain(51703, zksyncOSCTM, SemVer.packSemVer(0, 35, 0));

        checks.requireCoreUpgradeTargetHasNoLegacyChains(bridgehub);
    }

    function test_revertWhen_coreUpgradeTargetHostsAnEraVMChain() public {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 5790;
        chainIds[1] = 324;
        _setChainIds(chainIds);
        _registerChain(5790, zksyncOSCTM, SemVer.packSemVer(0, 33, 2));
        _registerChain(324, eraCTM, SemVer.packSemVer(0, 33, 0));

        vm.expectRevert(bytes("core upgrade refused: chain 324 is on an EraVM chain type manager"));
        checks.requireCoreUpgradeTargetHasNoLegacyChains(bridgehub);
    }

    function test_revertWhen_coreUpgradeTargetHostsAChainBelowV33() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 36900;
        _setChainIds(chainIds);
        _registerChain(36900, zksyncOSCTM, SemVer.packSemVer(0, 31, 2));

        vm.expectRevert(bytes("core upgrade refused: chain 36900 is on minor version 31, below 33"));
        checks.requireCoreUpgradeTargetHasNoLegacyChains(bridgehub);
    }

    function test_coreUpgradeTarget_operatorOverride_passes() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 36900;
        _setChainIds(chainIds);
        _registerChain(36900, zksyncOSCTM, SemVer.packSemVer(0, 31, 2));
        vm.setEnv(UpgradeSafetyChecks.ALLOW_LEGACY_CHAINS_ENV, "true");

        checks.requireCoreUpgradeTargetHasNoLegacyChains(bridgehub);

        vm.setEnv(UpgradeSafetyChecks.ALLOW_LEGACY_CHAINS_ENV, "false");
    }
}
