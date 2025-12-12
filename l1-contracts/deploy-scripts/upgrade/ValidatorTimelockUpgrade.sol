// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {Create2FactoryUtils} from "deploy-scripts/Create2FactoryUtils.s.sol";
import {MultisigCommitter} from "contracts/state-transition/MultisigCommitter.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

contract ValidatorTimelockUpgrade is Script, Create2FactoryUtils {
    function run(address ctm, uint32 initialExecutionDelay) external {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        address bridgehub = chainTypeManager.BRIDGE_HUB();
        address proxyAdmin = MultisigCommitter(validatorTimelock).owner();

        vm.startBroadcast();
        address implementation = deployImplementation(proxyAdmin, bridgehub);
        upgradeValidatorTimelock(validatorTimelock, implementation, proxyAdmin, initialExecutionDelay);
        vm.stopBroadcast();
    }

    function deployImplementation(address owner, address bridgehub) internal returns (address) {
        return
            deployViaCreate2AndNotify(
                type(MultisigCommitter).creationCode,
                abi.encode(bridgehub),
                "MultisigCommitter",
                false
            );
    }

    function upgradeValidatorTimelock(
        address proxy,
        address newImplementation,
        address admin,
        uint32 _initialExecutionDelay
    ) internal {
        vm.prank(ProxyAdmin(admin).owner());
        ProxyAdmin(admin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)),
            newImplementation,
            abi.encodeCall(MultisigCommitter.initializeV2, (admin, _initialExecutionDelay))
        );
    }

    function useCustomSigningSet(address validatorTimelock, address chain) public {
        bytes memory data = abi.encodeCall(MultisigCommitter.useCustomSigningSet, (chain));
        callWithoutUpgrade(validatorTimelock, data);
    }

    function setCustomSigningThreshold(address proxy, address chainAddress, uint64 newThreshold) public {
        bytes memory data = abi.encodeCall(MultisigCommitter.setCustomSigningThreshold, (chainAddress, newThreshold));
        callWithoutUpgrade(proxy, data);
    }

    function callWithoutUpgrade(address proxy, bytes memory data) internal {
        address admin = MultisigCommitter(proxy).owner();
        vm.prank(ProxyAdmin(admin).owner());
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(proxy));
        address implementation = proxy.implementation();
        vm.broadcast();
        ProxyAdmin(admin).upgradeAndCall(proxy, implementation, data);
    }
}
