// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Executes transactions from a protocol-ops --out JSON file.
/// Input: (string path, uint256 count) where path is the out file path and count is transactions.length.
/// Run with --broadcast, --private-key, --rpc-url. File path can be absolute or relative to project root.
contract ExecuteProtocolOpsOut is Script {
    using stdJson for string;

    function run(string memory outPath, uint256 transactionCount) external {
        string memory json = vm.readFile(outPath);
        vm.startBroadcast();
        for (uint256 i = 0; i < transactionCount; i++) {
            string memory baseKey = string.concat("$.transactions[", vm.toString(i), "]");
            address to = json.readAddress(string.concat(baseKey, ".to"));
            bytes memory data = json.readBytes(string.concat(baseKey, ".data"));
            uint256 value = json.readUint(string.concat(baseKey, ".value"));
            (bool success,) = to.call{value: value}(data);
            require(success, "ExecuteProtocolOpsOut: call reverted");
        }
        vm.stopBroadcast();
    }
}
