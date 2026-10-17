// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {ExecutionImplNew, ExecutionImplOld} from "./UpgradeBundleExecution.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @notice One executor per CTM: each `CTMUpgradeExecutor` is bound by immutables to one CTM and that
///         CTM's `ProxyAdmin`, so what it applies lands on that domain only; and the domain moves to a
///         successor executor through `forward` with no other contract to rebind
///         ({protocol-docs/ecosystem-upgrade-coordination.md}).
/// @dev A second real CTM, initialized on the same release, exists to show the binding is the
///      executor's: the same transition object is acceptable to both CTMs (it carries no CTM
///      pointer), and which CTM a governance call reaches is decided by the executor it targets —
///      which is why protocol-ops holds that executor's CTM against the reviewed one.
contract CTMExecutorDomainsTest is CTMUpgradeExecutorFixture {
    ChainTypeManager internal ctm2;
    CTMUpgradeExecutor internal ctmExecutor2;
    ProxyAdmin internal ctmProxyAdmin2;

    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal ctmDomainProxy;

    function setUp() public override {
        super.setUp();

        // The second CTM: same implementation and genesis shape as the fixture's, registered on
        // the Bridgehub, handed to its own executor, and initialized on the same real release.
        ctm2 = ChainTypeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(chainTypeManager),
                    admin,
                    abi.encodeCall(
                        IChainTypeManager.initialize,
                        ChainTypeManagerInitializeData({
                            owner: governor,
                            validatorTimelock: validator,
                            currentRelease: address(fromRelease),
                            serverNotifier: serverNotifier
                        })
                    )
                )
            )
        );
        vm.prank(governor);
        bridgehub.addChainTypeManager(address(ctm2));
        ctmProxyAdmin2 = new ProxyAdmin();
        ctmExecutor2 = new CTMUpgradeExecutor(governor, IChainTypeManager(address(ctm2)), ctmProxyAdmin2);
        ctmProxyAdmin2.transferOwnership(address(ctmExecutor2));
        vm.prank(governor);
        ctm2.transferOwnership(address(ctmExecutor2));
        ctmExecutor2.acceptCTMOwnership();
        assertEq(ctm2.currentRelease(), address(fromRelease));

        implOld = address(new ExecutionImplOld());
        implNew = address(new ExecutionImplNew());
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
    }

    function _replacement() internal returns (CTMUpgradeExecutor) {
        return new CTMUpgradeExecutor(governor, IChainTypeManager(address(chainContractAddress)), ctmProxyAdmin);
    }

    function test_revertWhen_constructedOverAZeroCTMOrAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new CTMUpgradeExecutor(governor, IChainTypeManager(address(0)), ctmProxyAdmin);
        vm.expectRevert(ZeroAddress.selector);
        new CTMUpgradeExecutor(governor, IChainTypeManager(address(chainContractAddress)), ProxyAdmin(address(0)));
        vm.expectRevert(ZeroAddress.selector);
        new CTMUpgradeExecutor(address(0), IChainTypeManager(address(chainContractAddress)), ctmProxyAdmin);
    }

    /// @dev The executor targeted decides the CTM: the second CTM's executor commits the same
    ///      transition on the second CTM only, and the fixture CTM stays where it was.
    function test_eachExecutorCommitsOnItsOwnCTMOnly() public {
        vm.prank(governor);
        ctmExecutor2.applyCTMUpgrade(ICTMTransition(address(transition)));

        assertEq(ctm2.upgradeTransition(0), address(transition), "the second CTM commits it");
        assertEq(ctm2.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "the fixture CTM commits nothing");
        assertEq(chainContractAddress.protocolVersion(), 0, "and does not move");

        // The object carries no CTM pointer, so the fixture CTM's own executor may commit it too.
        _execute(transition);
        assertEq(chainContractAddress.upgradeTransition(0), address(transition));
    }

    /// @dev An executor applies rows through ITS admin only: rows naming another CTM domain's proxy
    ///      cannot apply through the second CTM's executor, and the proxy stays where it was.
    function test_revertWhen_infrastructureNamesAProxyOfAnotherCTMDomain() public {
        ProxyUpgradeTransition infrastructure = _deployCTMInfrastructureTransition(
            _row(address(ctmDomainProxy), implOld, implNew)
        );
        // The proxy answers a non-admin by delegating to its implementation, which has no
        // `implementation()` — a revert without data.
        vm.expectRevert(bytes(""));
        vm.prank(governor);
        ctmExecutor2.applyInfrastructureUpgrade(infrastructure);
        assertEq(
            ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ctmDomainProxy))),
            implOld,
            "the other domain's proxy is untouched"
        );

        vm.prank(governor);
        ctmExecutor.applyInfrastructureUpgrade(infrastructure);
        assertEq(
            ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ctmDomainProxy))),
            implNew,
            "its own domain's executor applies it"
        );
    }

    /// @dev Succession: the domain (CTM + its ProxyAdmin) moves to a replacement executor over the
    ///      same CTM through the old one's `forward`, after which the replacement applies upgrades
    ///      and the predecessor no longer can. Nothing else names the executor, so nothing else is
    ///      rebound.
    function test_sameCTMExecutorReplacementCanRunAnUpgrade() public {
        CTMUpgradeExecutor previous = ctmExecutor;
        CTMUpgradeExecutor replacement = _replacement();
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (address(replacement)))
        });
        calls[1] = Call({
            target: address(ctmProxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(replacement)))
        });
        vm.prank(governor);
        previous.forward(calls);
        replacement.acceptCTMOwnership();
        assertEq(ctmProxyAdmin.owner(), address(replacement));
        assertEq(chainContractAddress.owner(), address(replacement));

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(governor);
        previous.applyCTMUpgrade(ICTMTransition(address(transition)));

        ctmExecutor = replacement;
        _execute(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(0), address(transition));
    }
}
