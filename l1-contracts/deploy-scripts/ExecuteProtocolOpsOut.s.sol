// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Executes transactions from a protocol-ops --out JSON file (`transactions` array).
/// @dev Run with --broadcast, --private-key, --rpc-url. Path may be absolute or relative (forge resolves via fs_permissions).
contract ExecuteProtocolOpsOut is Script {
    using stdJson for string;

    function run(string memory transactionsPath) external {
        string memory json = vm.readFile(transactionsPath);
        vm.startBroadcast();
        for (uint256 i; ; ++i) {
            string memory baseKey = string.concat("$.transactions[", vm.toString(i), "]");
            if (!json.keyExists(string.concat(baseKey, ".to"))) {
                break;
            }
            address to = json.readAddress(string.concat(baseKey, ".to"));
            bytes memory data = json.readBytes(string.concat(baseKey, ".data"));
            uint256 value = json.readUint(string.concat(baseKey, ".value"));
            (bool success, ) = to.call{value: value}(data);
            require(success, "ExecuteProtocolOpsOut: call reverted");
        }
        vm.stopBroadcast();
    }
}
