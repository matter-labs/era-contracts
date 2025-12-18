// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2 as console} from "forge-std/Script.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {Create2FactoryUtils} from "deploy-scripts/Create2FactoryUtils.s.sol";
import {MultisigCommitter} from "contracts/state-transition/MultisigCommitter.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Utils} from "deploy-scripts/Utils.sol";

contract ValidatorTimelockUpgrade is Script, Create2FactoryUtils {
    function run(address ctm, uint32 initialExecutionDelay) external {
        instantiateCreate2Factory();
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        console.logAddress(msg.sender);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        address bridgehub = chainTypeManager.BRIDGE_HUB();
        address proxyAdmin = Utils.getProxyAdminAddress(validatorTimelock);

        address implementation = deployImplementation(proxyAdmin, bridgehub);
        upgradeValidatorTimelock(validatorTimelock, implementation, proxyAdmin, initialExecutionDelay);
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
        vm.startBroadcast();
        ProxyAdmin(admin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)),
            newImplementation,
            abi.encodeCall(MultisigCommitter.initializeV2, (admin, _initialExecutionDelay))
        );
        vm.stopBroadcast();
    }

    function addSharedValidators(address[] memory validators, address ctm) public {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        for (uint256 i = 0; i < validators.length; i++) {
            bytes memory data = abi.encodeCall(MultisigCommitter.addSharedValidator, (validators[i]));
            callWithoutUpgrade(validatorTimelock, data);
        }
    }

    function removeSharedValidators(address[] memory validators, address ctm) public {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        for (uint256 i = 0; i < validators.length; i++) {
            bytes memory data = abi.encodeCall(MultisigCommitter.removeSharedValidator, (validators[i]));
            callWithoutUpgrade(validatorTimelock, data);
        }
    }

    function useSharedSigningSet(address ctm, uint256 chainId) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddreess(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.useSharedSigningSet, (chain));
        callWithoutUpgrade(validatorTimelock, data);
    }

    function useCustomSigningSet(address ctm, uint256 chainId) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddreess(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.useCustomSigningSet, (chain));
        callWithoutUpgrade(validatorTimelock, data);
    }

    function setCustomSigningThreshold(address ctm, uint256 chainId, uint64 newThreshold) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddreess(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.setCustomSigningThreshold, (chain, newThreshold));
        callWithoutUpgrade(validatorTimelock, data);
    }

    function getValidatorAndChainAddreess(address ctm, uint256 chainId) internal view returns (address, address) {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        address chain = chainTypeManager.getZKChain(chainId);
        return (validatorTimelock, chain);
    }

    function callWithoutUpgrade(address proxyAddress, bytes memory data) internal {
        address proxyAdmin = Utils.getProxyAdminAddress(proxyAddress);
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(proxyAddress));
        address implementation = Utils.getImplementation(proxyAddress);
        vm.broadcast();
        ProxyAdmin(proxyAdmin).upgradeAndCall(proxy, implementation, data);
    }
}
