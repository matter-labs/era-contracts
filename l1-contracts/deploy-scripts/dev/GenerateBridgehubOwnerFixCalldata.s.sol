// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Call} from "contracts/governance/Common.sol";

/// @title GenerateBridgehubOwnerFixCalldata
/// @author Matter Labs
/// @notice Generates the governance calldata that repairs the misconfigured Bridgehub proxy
///         whose `_owner` is `address(0)` (the `initialize` call never set an owner).
///
/// The fix is a single Governance operation (multicall) containing two calls on the proxy's
/// `ProxyAdmin`:
///   1. `upgradeAndCall(proxy, tempImpl, forceSetOwner(newOwner))`
///        -> points the proxy at the temporary `BridgehubOwnerForceUpdate` implementation and,
///           atomically, calls `forceSetOwner`, which writes the OpenZeppelin `_owner` slot.
///   2. `upgrade(proxy, originalImpl)`
///        -> points the proxy back at the original implementation.
///
/// Because both calls live in one operation they execute atomically: the temporary
/// implementation is only installed for the duration of call (1).
///
/// The script emits a JSON array (to `script-out/bridgehub-owner-fix-calldata.json`) describing
/// the two transactions the EOA owner of the Governance contract must send:
///   - `scheduleTransparent(operation, 0)`
///   - `execute(operation)`
/// (`minDelay` on the target Governance is 0, so the operation is executable in the same block.)
///
/// All addresses default to the ZKsync Sepolia deployment that needs fixing and can be
/// overridden via environment variables.
contract GenerateBridgehubOwnerFixCalldata is Script {
    struct Config {
        string network;
        address proxy; // the TransparentUpgradeableProxy whose owner is address(0)
        address proxyAdmin; // the proxy's ProxyAdmin
        address governance; // the Governance contract that owns the ProxyAdmin
        address governanceOwner; // the EOA that owns the Governance contract (tx sender)
        address originalImpl; // the currently installed implementation, restored at the end
        address tempImpl; // the deployed & verified temporary impl exposing forceSetOwner
        address newOwner; // the correct owner to set
        bytes32 salt; // unique salt for the governance operation
    }

    function _config() internal view returns (Config memory c) {
        c.network = vm.envOr("NETWORK", string("sepolia"));
        c.proxy = vm.envOr("BRIDGEHUB_PROXY", 0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C);
        c.proxyAdmin = vm.envOr("PROXY_ADMIN", 0xE00456791Da489418355B0a6b27965A54c7C01d2);
        c.governance = vm.envOr("GOVERNANCE", 0xcf96aAb01347BA96050F39Ff6dcbC6138b462b58);
        c.governanceOwner = vm.envOr("GOVERNANCE_OWNER", 0x5555555590930f501c88B73Ea43B3EEb5A71643c);
        c.originalImpl = vm.envOr("ORIGINAL_IMPL", 0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F);
        c.tempImpl = vm.envOr("TEMP_IMPL", 0xA28C7C88037e42103e606477d2754A50D87B9E0A);
        c.newOwner = vm.envOr("NEW_OWNER", 0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D);
        c.salt = vm.envOr("SALT", keccak256(abi.encodePacked("BridgehubOwnerFix", c.proxy, c.newOwner)));
    }

    function run() external {
        Config memory c = _config();

        // Inner calldata.
        bytes memory forceSetOwnerData = abi.encodeWithSignature("forceSetOwner(address)", c.newOwner);
        bytes memory upgradeAndCallData = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            c.proxy,
            c.tempImpl,
            forceSetOwnerData
        );
        bytes memory upgradeData = abi.encodeWithSignature("upgrade(address,address)", c.proxy, c.originalImpl);

        // The governance operation (multicall): set temp impl + forceSetOwner, then restore original impl.
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: c.proxyAdmin, value: 0, data: upgradeAndCallData});
        calls[1] = Call({target: c.proxyAdmin, value: 0, data: upgradeData});
        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: c.salt
        });

        bytes memory scheduleData = abi.encodeCall(IGovernance.scheduleTransparent, (operation, 0));
        bytes memory executeData = abi.encodeCall(IGovernance.execute, (operation));

        _log(c, forceSetOwnerData, upgradeAndCallData, upgradeData);

        string memory json = _buildJson(c, scheduleData, executeData);
        string memory outPath = "script-out/bridgehub-owner-fix-calldata.json";
        vm.writeFile(outPath, json);
        console.log("Wrote calldata JSON to:", outPath);
    }

    function _log(
        Config memory c,
        bytes memory forceSetOwnerData,
        bytes memory upgradeAndCallData,
        bytes memory upgradeData
    ) internal pure {
        console.log("== Bridgehub owner fix calldata ==");
        console.log("network:           ", c.network);
        console.log("proxy (Bridgehub): ", c.proxy);
        console.log("proxyAdmin:        ", c.proxyAdmin);
        console.log("governance:        ", c.governance);
        console.log("governanceOwner:   ", c.governanceOwner);
        console.log("originalImpl:      ", c.originalImpl);
        console.log("tempImpl:          ", c.tempImpl);
        console.log("newOwner:          ", c.newOwner);
        console.log("salt:");
        console.logBytes32(c.salt);
        console.log("forceSetOwner data:");
        console.logBytes(forceSetOwnerData);
        console.log("upgradeAndCall data:");
        console.logBytes(upgradeAndCallData);
        console.log("upgrade data:");
        console.logBytes(upgradeData);
    }

    function _buildJson(
        Config memory c,
        bytes memory scheduleData,
        bytes memory executeData
    ) internal pure returns (string memory) {
        string memory step1 = _txObject(
            "[1/2] Schedule the governance operation that fixes the Bridgehub owner (delay 0).",
            c.network,
            c.governanceOwner,
            c.governance,
            scheduleData
        );
        string memory step2 = _txObject(
            "[2/2] Execute the scheduled governance operation: set temp impl + forceSetOwner, then restore the original impl.",
            c.network,
            c.governanceOwner,
            c.governance,
            executeData
        );
        return string.concat("[\n", step1, ",\n", step2, "\n]\n");
    }

    function _txObject(
        string memory description,
        string memory network,
        address from,
        address to,
        bytes memory data
    ) internal pure returns (string memory) {
        return
            string.concat(
                "  {\n",
                '    "description": "',
                description,
                '",\n',
                '    "network": "',
                network,
                '",\n',
                '    "from": "',
                vm.toString(from),
                '",\n',
                '    "to": "',
                vm.toString(to),
                '",\n',
                '    "data": "',
                vm.toString(data),
                '",\n',
                '    "value": "0",\n',
                '    "valueToMint": "0"\n',
                "  }"
            );
    }
}
