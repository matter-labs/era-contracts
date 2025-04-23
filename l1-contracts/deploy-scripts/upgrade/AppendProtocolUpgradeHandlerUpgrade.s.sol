// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Call} from "contracts/governance/Common.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

// Note that the `ProtocolUpgradeHandler` uses `OpenZeppeling v5`.
interface ProxyAdminV5 {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external;
}

contract AppendProtocolUpgradeHandlerUpgrade is Script {
    using stdToml for string;

    function getProxyAdmin(address _proxyAddr) internal view returns (address proxyAdmin) {
        // the constant is the proxy admin storage slot
        proxyAdmin = address(
            uint160(
                uint256(
                    vm.load(_proxyAddr, bytes32(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103))
                )
            )
        );
    }

    function run() public {
        string memory root = vm.projectRoot();
        string memory config = vm.envString("GATEWAY_UPGRADE_ECOSYSTEM_INPUT");

        string memory configPath = string.concat(root, config);

        string memory toml = vm.readFile(configPath);

        address protocolUpgradeHandlerProxyAddress = toml.readAddress("$.protocol_upgrade_handler_proxy_address");
        address transparentProxyAdmin = getProxyAdmin(protocolUpgradeHandlerProxyAddress);
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

        console.logBytes(abi.encode(newCalls));
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
                    ProxyAdminV5.upgradeAndCall,
                    (protocolUpgradeHandlerProxyAddress, protocolUpgradeHandlerImplAddress, hex"")
                ),
                value: 0
            });
    }
}
