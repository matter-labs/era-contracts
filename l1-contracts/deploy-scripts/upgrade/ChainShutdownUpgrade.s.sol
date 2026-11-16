// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Call} from "contracts/governance/Common.sol";
import {DenyAllTransactionFilterer} from "contracts/transactionFilterer/DenyAllTransactionFilterer.sol";

import {Create2FactoryUtils} from "deploy-scripts/utils/deploy/Create2FactoryUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @notice Adds chain shutdown support to an ecosystem without a new protocol version: deploys the new
/// `L1AssetTracker` and `L1NativeTokenVault` implementations and the `DenyAllTransactionFilterer` that shutdowns
/// install, and writes the governance calls that upgrade the two proxies.
/// @dev The constructor arguments of the new implementations are read from the live proxies, so the immutables stay
/// the same. Neither upgrade needs an initializer: the new storage of `L1AssetTracker` is only appended mappings.
/// Usage: `forge script ChainShutdownUpgrade --sig "run(address)" <bridgehub> --rpc-url <l1-rpc> --broadcast`,
/// the output path can be set with `CHAIN_SHUTDOWN_UPGRADE_OUTPUT` (relative to the project root).
contract ChainShutdownUpgrade is Script, Create2FactoryUtils {
    string internal constant DEFAULT_OUTPUT = "/script-out/chain-shutdown-upgrade.toml";

    struct Output {
        address assetTrackerImplementation;
        address nativeTokenVaultImplementation;
        address denyAllTransactionFilterer;
        Call[] governanceCalls;
    }

    function run(address _bridgehub) external {
        Output memory output = runInner(_bridgehub);
        saveOutput(output, string.concat(vm.projectRoot(), vm.envOr("CHAIN_SHUTDOWN_UPGRADE_OUTPUT", DEFAULT_OUTPUT)));
    }

    function runInner(address _bridgehub) internal returns (Output memory output) {
        L1NativeTokenVault nativeTokenVault = L1NativeTokenVault(
            payable(address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault()))
        );
        L1AssetTracker assetTracker = L1AssetTracker(address(nativeTokenVault.l1AssetTracker()));

        output.assetTrackerImplementation = deployViaCreate2AndNotify(
            type(L1AssetTracker).creationCode,
            abi.encode(assetTracker.BRIDGE_HUB(), assetTracker.NATIVE_TOKEN_VAULT(), assetTracker.MESSAGE_ROOT()),
            "L1AssetTracker",
            false
        );
        output.nativeTokenVaultImplementation = deployViaCreate2AndNotify(
            type(L1NativeTokenVault).creationCode,
            abi.encode(nativeTokenVault.WETH_TOKEN(), nativeTokenVault.ASSET_ROUTER(), nativeTokenVault.L1_NULLIFIER()),
            "L1NativeTokenVault",
            false
        );
        output.denyAllTransactionFilterer = deployViaCreate2AndNotify(
            type(DenyAllTransactionFilterer).creationCode,
            "",
            "DenyAllTransactionFilterer",
            false
        );

        output.governanceCalls = new Call[](2);
        output.governanceCalls[0] = prepareUpgradeCall(address(assetTracker), output.assetTrackerImplementation);
        output.governanceCalls[1] = prepareUpgradeCall(
            address(nativeTokenVault),
            output.nativeTokenVaultImplementation
        );
    }

    function prepareUpgradeCall(address _proxy, address _implementation) internal view returns (Call memory) {
        return
            Call({
                target: Utils.getProxyAdminAddress(_proxy),
                data: abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(_proxy), _implementation)),
                value: 0
            });
    }

    function saveOutput(Output memory _output, string memory _path) internal {
        console.log("Governance calls:");
        console.logBytes(abi.encode(_output.governanceCalls));

        vm.serializeAddress("root", "l1_asset_tracker_implementation_addr", _output.assetTrackerImplementation);
        vm.serializeAddress(
            "root",
            "l1_native_token_vault_implementation_addr",
            _output.nativeTokenVaultImplementation
        );
        vm.serializeAddress("root", "deny_all_transaction_filterer_addr", _output.denyAllTransactionFilterer);
        string memory toml = vm.serializeBytes("root", "governance_calls", abi.encode(_output.governanceCalls));
        vm.writeToml(toml, _path);
    }
}
