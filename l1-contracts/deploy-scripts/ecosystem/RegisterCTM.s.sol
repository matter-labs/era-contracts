// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IRegisterCTM} from "contracts/script-interfaces/IRegisterCTM.sol";

contract RegisterCTM is Script, IRegisterCTM {
    using stdToml for string;

    struct Output {
        address governance;
        bytes encodedData;
    }

    /// @notice Returns the address to use as the deployer/owner for contracts.
    /// @dev This is virtual so test scripts can override it. By default returns tx.origin.
    function getDeployerAddress() public view virtual returns (address) {
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
    ) internal {
        string memory root = vm.projectRoot();

        registerChainTypeManager(outputPath, bridgehub, chainTypeManagerProxy, shouldSend);
    }

    function registerChainTypeManager(
        string memory outputPath,
        address bridgehubProxy,
        address chainTypeManagerProxy,
        bool shouldSend
    ) internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubProxy);
        address ctmDeploymentTrackerProxy = address(bridgehub.l1CtmDeployer());
        address l1AssetRouterProxy = address(bridgehub.assetRouter());

        vm.startBroadcast(msg.sender);
        IGovernance governance = IGovernance(IOwnable(bridgehubProxy).owner());
        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            target: bridgehubProxy,
            value: 0,
            data: abi.encodeCall(bridgehub.addChainTypeManager, (chainTypeManagerProxy))
        });
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(l1AssetRouterProxy);
        calls[1] = Call({
            target: address(sharedBridge),
            value: 0,
            data: abi.encodeCall(
                sharedBridge.setAssetDeploymentTracker,
                (bytes32(uint256(uint160(chainTypeManagerProxy))), address(ctmDT))
            )
        });
        calls[2] = Call({
            target: address(ctmDT),
            value: 0,
            data: abi.encodeCall(ctmDT.registerCTMAssetOnL1, (chainTypeManagerProxy))
        });

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

    function registerChainTypeManagerForTest(address bridgehubProxy, address chainTypeManagerProxy) internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubProxy);
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

    function saveOutput(Output memory output, string memory outputPath) internal {
        vm.serializeAddress("root", "admin_address", output.governance);
        string memory toml = vm.serializeBytes("root", "encoded_data", output.encodedData);
        string memory path = string.concat(vm.projectRoot(), outputPath);
        vm.writeToml(toml, path);
    }
}
