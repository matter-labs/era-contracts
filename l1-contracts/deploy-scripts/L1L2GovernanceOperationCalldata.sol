// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {IERC20} from 'forge-std/interfaces/IERC20.sol';
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Utils} from "./Utils.sol";

contract PrepareZKChainRegistrationCalldataScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;

    struct Config {
        address bridgehub;
        uint256 chainId;
        address baseToken;
        address governance;
        address l1SharedBridgeProxy;
        address l2Contract;
        bytes l2Calldata;
        uint256 approveTokens;
    }

    Config internal config;

    function run() public {
        console.log("Preparing governance tx calldata");

        initializeConfig();

        IGovernance.Call[] memory calls = new IGovernance.Call[](2);
        calls[0] = approveBaseTokenCall();
        calls[1] = bridegehubCall();

        scheduleTransparentCalldata(calls);
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-l1-l2-governance-operation-calldata.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.chainId = toml.readUint("$.chain.chain_id");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.governance = toml.readAddress("$.chain.governance_addr");
        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub_proxy_addr");
        config.l1SharedBridgeProxy = toml.readAddress("$.deployed_addresses.l1_shared_bridge_proxy_addr");

        config.l2Contract = toml.readAddress("$.l2_contract_addr");
        config.l2Calldata = toml.readBytes("$.l2_contract_calldata");
        config.approveTokens = uint256(toml.readUint("$.approve_tokens"));
    }

    function approveBaseTokenCall() internal view returns (IGovernance.Call memory) {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        address baseTokenAddress = bridgehub.baseToken(config.chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            IERC20 baseToken = IERC20(config.baseToken);
            uint8 decimals = baseToken.decimals();

            bytes memory data = abi.encodeWithSignature("approve(address,uint256)", config.l1SharedBridgeProxy, config.approveTokens * 10 ** decimals);

            console.log("Approve ", config.approveTokens, " tokens to ", config.l1SharedBridgeProxy);
            console.log("Decimals: ", decimals);

            return IGovernance.Call({target: config.baseToken, value: 0, data: data});
        }

        return IGovernance.Call({target: ADDRESS_ONE, value: 0, data: new bytes(0)});
    }


    function bridegehubCall() internal returns (IGovernance.Call memory){
        bytes memory data = Utils.getL1L2TransactionCalldata(
            config.l2Calldata,
            400000,
            new bytes[](0), // factoryDeps
            config.l2Contract,
            config.chainId,
            config.bridgehub
        );

        return IGovernance.Call({target: config.bridgehub, value: 0, data: data});
    }

    function scheduleTransparentCalldata(
        IGovernance.Call[] memory calls
    ) internal {
        IGovernance governance = IGovernance(config.governance);

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        bytes memory scheduleCalldata = abi.encodeCall(governance.scheduleTransparent, (operation, 0));
        bytes memory executeCalldata = abi.encodeCall(governance.execute, (operation));
        console.log("Completed");

        saveOutput(scheduleCalldata, executeCalldata);
    }

    function saveOutput(
        bytes memory schedule,
        bytes memory execute
    ) internal {
        vm.serializeBytes("root", "scheduleCalldataStageOne", schedule);
        string memory toml = vm.serializeBytes("root", "executeCalldataStageOne", execute);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-prepare-l1-l2-op-calldata.toml");
        vm.writeToml(toml, path);
    }
}
