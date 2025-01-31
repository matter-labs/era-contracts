// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract AppendProtocolUpgradeHandlerUpgrade is Script {
    using stdToml for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory config = vm.envString("GATEWAY_UPGRADE_ECOSYSTEM_INPUT");

        string memory configPath = string.concat(root, config);

        string memory toml = vm.readFile(configPath);

        address transparentProxyAdmin = toml.readAddress("$.contracts_config.transparent_proxy_admin");
        address protocolUpgradeHandlerProxyAddress = toml.readAddress("$.protocol_upgrade_handler_proxy_address");
        address protocolUpgradeHandlerImplAddress = toml.readAddress("$.protocol_upgrade_handler_impl_address");

        bytes memory stage2CallsRaw = toml.readBytes("$.governance_stage2_calls");

        Call[] memory calls = abi.decode(stage2CallsRaw, (Call[]));

        Call[] memory newCalls = new Call[](calls.length + 1);

        for (uint256 i = 0; i < calls.length; ++i) {
            newCalls[i] = calls[i];
        }

        newCalls[calls.length] = generateProtocolUpgradeHandlerUpgradeCall(
            transparentProxyAdmin,
            protocolUpgradeHandlerProxyAddress,
            protocolUpgradeHandlerImplAddress
        );

        console.logBytes(
            abi.encode(newCalls)
        );
    }

    function generateProtocolUpgradeHandlerUpgradeCall(
        address transparentProxyAdmin,
        address protocolUpgradeHandlerProxyAddress,
        address protocolUpgradeHandlerImplAddress
    ) internal returns (Call memory) {
        return
            Call({
                target: transparentProxyAdmin,
                data: abi.encodeCall(
                    ProxyAdmin.upgrade,
                    (
                        ITransparentUpgradeableProxy(payable(protocolUpgradeHandlerProxyAddress)),
                        protocolUpgradeHandlerImplAddress
                    )
                ),
                value: 0
            });
    }
}
