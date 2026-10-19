// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IRegisterCTM} from "contracts/script-interfaces/IRegisterCTM.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";

contract RegisterCTM is Script, IRegisterCTM {
    using stdToml for string;

    struct Output {
        address governance;
        bytes encodedData;
    }

    /// @notice Returns the address to use as the deployer/owner for contracts.
    function getDeployerAddress() public view returns (address) {
        return tx.origin;
    }

    function registerCTM(address bridgehub, address chainTypeManagerProxy, bool shouldSend) public virtual {
        console.log("Registering CTM for L1 contracts");

        runInner("/script-out/register-ctm-l1.toml", bridgehub, chainTypeManagerProxy, shouldSend);
    }

    function runForTest(address bridgehub, address chainTypeManagerProxy) public {
        registerChainTypeManagerForTest(bridgehub, chainTypeManagerProxy);
    }

    function runInner(
        string memory outputPath,
        address bridgehub,
        address chainTypeManagerProxy,
        bool shouldSend
    ) public {
        registerChainTypeManager(outputPath, bridgehub, chainTypeManagerProxy, shouldSend);
    }

    function registerChainTypeManager(
        string memory outputPath,
        address bridgehubProxy,
        address chainTypeManagerProxy,
        bool shouldSend
    ) internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubProxy);
        address l1AssetRouterProxy = address(bridgehub.assetRouter());

        vm.startBroadcast(getDeployerAddress());
        IGovernance governance = IGovernance(IOwnable(bridgehubProxy).owner());
        Call[] memory calls = _registrationCalls(bridgehub, chainTypeManagerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(l1AssetRouterProxy);

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        if (shouldSend) {
            governance.scheduleTransparent(operation, 0);
            // We assume that the total value is 0
            governance.execute{value: 0}(operation);

            console.log("CTM DT whitelisted");
            vm.stopBroadcast();

            bytes32 assetId = bridgehub.ctmAssetIdFromAddress(chainTypeManagerProxy);
            console.log(
                "CTM in router 2",
                sharedBridge.assetHandlerAddress(assetId),
                bridgehub.ctmAssetIdToAddress(assetId)
            );
        }
        saveOutput(Output({governance: address(governance), encodedData: abi.encode(calls)}), outputPath);
    }

    /// @dev Governance's registration batch: the CTM on the Bridgehub, its asset handler on the asset
    ///      router and the deployment tracker.
    /// @param _bridgehub The Bridgehub.
    /// @param _ctm The CTM being registered.
    function _registrationCalls(IL1Bridgehub _bridgehub, address _ctm) internal view returns (Call[] memory calls) {
        ICTMDeploymentTracker ctmDT = _bridgehub.l1CtmDeployer();
        IL1AssetRouter sharedBridge = IL1AssetRouter(address(_bridgehub.assetRouter()));
        _requireCTMExecutor(_ctm);
        calls = new Call[](3);
        calls[0] = Call({
            target: address(_bridgehub),
            value: 0,
            data: abi.encodeCall(_bridgehub.addChainTypeManager, (_ctm))
        });
        calls[1] = Call({
            target: address(sharedBridge),
            value: 0,
            data: abi.encodeCall(
                sharedBridge.setAssetDeploymentTracker,
                (bytes32(uint256(uint160(_ctm))), address(ctmDT))
            )
        });
        calls[2] = Call({target: address(ctmDT), value: 0, data: abi.encodeCall(ctmDT.registerCTMAssetOnL1, (_ctm))});
    }

    function registerChainTypeManagerForTest(address bridgehubProxy, address chainTypeManagerProxy) internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubProxy);
        _requireCTMExecutor(chainTypeManagerProxy);
        vm.startBroadcast(getDeployerAddress());
        bridgehub.addChainTypeManager(chainTypeManagerProxy);
        console.log("ChainTypeManager registered");
        address ctmDeploymentTrackerProxy = address(bridgehub.l1CtmDeployer());
        address l1AssetRouterProxy = address(bridgehub.assetRouter());
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(l1AssetRouterProxy);
        sharedBridge.setAssetDeploymentTracker(bytes32(uint256(uint160(chainTypeManagerProxy))), address(ctmDT));
        console.log("CTM DT whitelisted");

        ctmDT.registerCTMAssetOnL1(chainTypeManagerProxy);
        vm.stopBroadcast();
        console.log("CTM registered in CTMDeploymentTracker");

        bytes32 assetId = bridgehub.ctmAssetIdFromAddress(chainTypeManagerProxy);
        console.log(
            "CTM in router 1",
            sharedBridge.assetHandlerAddress(assetId),
            bridgehub.ctmAssetIdToAddress(assetId)
        );
    }

    /// @dev Requires the CTM to be under the registry upgrade lifecycle: owned by the CTM executor
    ///      `DeployCTM` handed it to.
    /// @param _ctm The CTM being registered.
    function _requireCTMExecutor(address _ctm) internal view {
        address ctmOwner = IOwnable(_ctm).owner();
        require(ctmOwner.code.length != 0, "the CTM is not owned by a CTMUpgradeExecutor");
        CTMUpgradeExecutor executor = CTMUpgradeExecutor(payable(ctmOwner));
        require(address(executor.CHAIN_TYPE_MANAGER()) == _ctm, "the CTM owner is not the executor bound to it");
    }

    function saveOutput(Output memory output, string memory outputPath) internal {
        vm.serializeAddress("root", "admin_address", output.governance);
        string memory toml = vm.serializeBytes("root", "encoded_data", output.encodedData);
        string memory path = string.concat(vm.projectRoot(), outputPath);
        vm.writeToml(toml, path);
    }
}
