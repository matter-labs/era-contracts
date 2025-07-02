// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {Script, console2 as console} from "forge-std/Script.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {Transaction} from "./BroadcastTypes.sol";

contract BroadcastUtils is Script {
    using stdJson for string;

    function getHashesForChainAndSelector(uint256 chainId, string memory selector) public returns (bytes32[] memory) {
        string memory originalPath = string.concat(
            vm.projectRoot(),
            "/broadcast/GatewayMigrateTokenBalances.s.sol/",
            vm.toString(chainId),
            selector,
            "latest.json"
        );
        parseBroadcastFile(originalPath);
        string memory path = string.concat(
            vm.projectRoot(),
            "/broadcast/GatewayMigrateTokenBalances.s.sol/",
            vm.toString(chainId),
            selector,
            "latest.parsed.json"
        );
        // console.log("path", path);
        string memory json = vm.readFile(path);

        uint256 length = 0;
        bytes memory transactionBytes = vm.parseJson(json, "$.transactions");
        Transaction[] memory transactions = abi.decode(transactionBytes, (Transaction[]));
        length = transactions.length;
        // console.log("length", length);

        // string[] memory keys = vm.parseJsonKeys(json, "$.transactions");
        // length = keys.length;
        // console.log("length", length);
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            hashes[i] = json.readBytes32(string.concat("$.transactions[", vm.toString(i), "].hash"));
            // console.logBytes32(hashes[i]);
        }
        // console.log("successfully parsed hashes");
        return hashes;
    }

    function parseBroadcastFile(string memory path) public {
        string[] memory inputs = new string[](3);
        inputs[0] = "sh";
        inputs[1] = "scripts/parse-broadcast.sh";
        inputs[2] = path;

        bytes memory result = vm.ffi(inputs);
        console.log("FFI result:", string(result));
    }
}
