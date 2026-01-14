// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {Create2FactoryUtils} from "deploy-scripts/Create2FactoryUtils.s.sol";
import {MultisigCommitter} from "contracts/state-transition/MultisigCommitter.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Utils} from "deploy-scripts/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

contract ValidatorTimelockUpgrade is Script, Create2FactoryUtils {
    using stdToml for string;
    string internal defaultOutput = "/script-out/validator_timelock_upgrade.toml";

    function run(address ctm) external {
        string memory output = vm.envOr("OUTPUT_FILE", defaultOutput);
        Call[] memory calls = runInner(ctm);
        printAndSaveCalls(calls, "upgrade_validator_timelock_calls", output);
    }

    function runInner(address ctm) internal returns (Call[] memory calls) {
        instantiateCreate2Factory();
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        console.logAddress(msg.sender);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        address bridgehub = chainTypeManager.BRIDGE_HUB();
        address owner = IOwnable(validatorTimelock).owner();
        address proxyAdmin = Utils.getProxyAdminAddress(validatorTimelock);

        address implementation = deployImplementation(owner, bridgehub);
        calls = prepareUpgradeValidatorTimelockCall(validatorTimelock, implementation, proxyAdmin);
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

    function prepareUpgradeValidatorTimelockCall(
        address proxy,
        address newImplementation,
        address admin
    ) public virtual returns (Call[] memory calls) {
        calls = prepareGovernanceCallWithUpgrade(
            proxy,
            abi.encodeCall(MultisigCommitter.reinitializeV2, ()),
            newImplementation
        );
    }

    function addSharedValidators(address[] memory validators, address ctm) public {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        Call[] memory calls = new Call[](0);
        for (uint256 i = 0; i < validators.length; i++) {
            bytes memory data = abi.encodeCall(MultisigCommitter.addSharedValidator, (validators[i]));
            calls = Utils.mergeCalls(calls, prepareChainAdminCall(validatorTimelock, data));
        }
        printAndSaveCalls(calls, "add_shared_validators", defaultOutput);
    }

    function removeSharedValidators(address[] memory validators, address ctm) public {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        Call[] memory calls = new Call[](0);
        for (uint256 i = 0; i < validators.length; i++) {
            bytes memory data = abi.encodeCall(MultisigCommitter.removeSharedValidator, (validators[i]));
            calls = Utils.mergeCalls(calls, prepareChainAdminCall(validatorTimelock, data));
        }
        printAndSaveCalls(calls, "remove_shared_validators", defaultOutput);
    }

    function useSharedSigningSet(address ctm, uint256 chainId) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddress(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.useSharedSigningSet, (chain));
        Call[] memory calls = prepareChainAdminCall(validatorTimelock, data);
        printAndSaveCalls(calls, "use_shared_signing_set", defaultOutput);
    }

    function useCustomSigningSet(address ctm, uint256 chainId) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddress(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.useCustomSigningSet, (chain));
        Call[] memory calls = prepareChainAdminCall(validatorTimelock, data);
        printAndSaveCalls(calls, "use_custom_signing_set", defaultOutput);
    }

    function setCustomSigningThreshold(address ctm, uint256 chainId, uint64 newThreshold) public {
        (address validatorTimelock, address chain) = getValidatorAndChainAddress(ctm, chainId);
        bytes memory data = abi.encodeCall(MultisigCommitter.setCustomSigningThreshold, (chain, newThreshold));
        Call[] memory calls = prepareChainAdminCall(validatorTimelock, data);
        printAndSaveCalls(calls, "set_custom_signing_threshold", defaultOutput);
    }

    function getValidatorAndChainAddress(address ctm, uint256 chainId) internal view returns (address, address) {
        ZKsyncOSChainTypeManager chainTypeManager = ZKsyncOSChainTypeManager(ctm);
        address validatorTimelock = chainTypeManager.validatorTimelockPostV29();
        address chain = chainTypeManager.getZKChain(chainId);
        return (validatorTimelock, chain);
    }

    function prepareChainAdminCall(address proxyAddress, bytes memory data) internal returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: proxyAddress, data: data, value: 0});
    }

    function prepareGovernanceCallWithUpgrade(
        address proxyAddress,
        bytes memory data,
        address implementation
    ) internal view returns (Call[] memory calls) {
        address proxyAdmin = Utils.getProxyAdminAddress(proxyAddress);
        bytes memory upgradeAndCallData = abi.encodeWithSelector(
            ProxyAdmin.upgradeAndCall.selector,
            ITransparentUpgradeableProxy(payable(proxyAddress)),
            implementation,
            data
        );
        calls = new Call[](1);
        calls[0] = Call({target: proxyAdmin, data: upgradeAndCallData, value: 0});
    }

    /// Misc helpers for calls

    function printCalls(Call[] memory calls) internal pure {
        console.log("Calls for the governance proposal:");

        for (uint256 i = 0; i < calls.length; i++) {
            console.log("Call to:", calls[i].target);
            console.logBytes(calls[i].data);
            console.log("Value:", calls[i].value);
        }
    }

    function saveCalls(Call[] memory calls, string memory callNames, string memory output) internal {
        string memory governanceCallsSerialized = vm.serializeBytes("root", callNames, abi.encode(calls));

        vm.writeToml(governanceCallsSerialized, output);
    }

    function printAndSaveCalls(Call[] memory calls, string memory callNames, string memory output) internal {
        printCalls(calls);
        if (bytes(output).length > 0) {
            output = string.concat(vm.projectRoot(), output);
            saveCalls(calls, callNames, output);
        }
    }
}
