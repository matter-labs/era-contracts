// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Call} from "contracts/governance/Common.sol";
import {Utils} from "../utils/Utils.sol";

// Note that the `ProtocolUpgradeHandler` uses `OpenZeppeling v5`.
interface IProxyAdminV5 {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external;
}

contract AppendProtocolUpgradeHandlerUpgrade is Script {
    using stdToml for string;

    function run() public view {
        string memory root = vm.projectRoot();
        string memory config = vm.envString("GATEWAY_UPGRADE_ECOSYSTEM_INPUT");

        string memory configPath = string.concat(root, config);

        string memory toml = vm.readFile(configPath);

        address protocolUpgradeHandlerProxyAddress = toml.readAddress("$.protocol_upgrade_handler_proxy_address");
        address transparentProxyAdmin = Utils.getProxyAdminAddress(protocolUpgradeHandlerProxyAddress);
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
    ) internal pure returns (Call memory) {
        return
            Call({
                target: transparentProxyAdmin,
                data: abi.encodeCall(
                    IProxyAdminV5.upgradeAndCall,
                    (protocolUpgradeHandlerProxyAddress, protocolUpgradeHandlerImplAddress, hex"")
                ),
                value: 0
            });
    }
}
