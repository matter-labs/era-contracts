// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2SharedBridge} from "../contracts/bridge/L2SharedBridge.sol";
import {L2StandardERC20} from "../contracts/bridge/L2StandardERC20.sol";
import {L2WrappedBaseToken} from "../contracts/bridge/L2WrappedBaseToken.sol";
import {UpgradeableBeacon} from "../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "../lib/openzeppelin-contracts-v4/contracts/proxy/transparent/ProxyAdmin.sol";

/*
Run the following script with:
    forge script --zksync scripts/DeployL2BridgesAndTokens.s.sol --sig "run(uint256,address,address)" $CHAIN_ID $L2_SHARED_BRIDGE_PROXY $L2_WETH_PROXY --private-key $PRIV_KEY --rpc-url $RPC_URL -vv
Append `--broadcast` to send transactions
*/

contract DeployL2BridgesAndTokensScript is Script {
    function setUp() public {}

    function run(uint256 _chainId, address _l2SharedBridgeProxy, address _l2WETHProxy) public {
        vm.startBroadcast();
        console.log("Using deployer: %s\n", msg.sender);

        console.log("DEPLOYING BRIDGE IMPLEMENTATIONS");
        
        L2SharedBridge sharedBridgeImpl = new L2SharedBridge(_chainId);
        console.log("\tL2SharedBridge Address: %s\n", address(sharedBridgeImpl));
        
        console.log("DEPLOYING TOKEN IMPLEMENTATIONS");

        L2StandardERC20 standardERC20Impl = new L2StandardERC20();
        console.log("\tL2StandardERC20 Address: %s", address(standardERC20Impl));
        
        L2WrappedBaseToken wrappedBaseTokenImpl = new L2WrappedBaseToken();
        console.log("\tL2WrappedBaseToken Address: %s\n", address(wrappedBaseTokenImpl));

        vm.stopBroadcast();

        console.log("UPGRADE CALLDATA");

        bytes memory upgradeSharedBridgeCalldata = abi.encodeWithSelector(
            ProxyAdmin.upgrade.selector,
            _l2SharedBridgeProxy,
            address(sharedBridgeImpl)
        );
        console.log("\tUpgrade L2SharedBridge Calldata: %s", _bytesToHex(upgradeSharedBridgeCalldata));

        bytes memory upgradeL2StandardTokenBeaconCalldata = abi.encodeWithSelector(
            UpgradeableBeacon.upgradeTo.selector,
            address(standardERC20Impl)
        );
        console.log("\tUpgrade L2StandardToken Beacon Calldata: %s", _bytesToHex(upgradeL2StandardTokenBeaconCalldata));

        bytes memory upgradeL2WETHCalldata = abi.encodeWithSelector(
            ProxyAdmin.upgrade.selector,
            _l2WETHProxy,
            address(wrappedBaseTokenImpl)
        );
        console.log("\tUpgrade L2WETH Calldata: %s", _bytesToHex(upgradeL2WETHCalldata));
    }

    function _bytesToHex(bytes memory buffer) internal pure returns (string memory) {

        // Fixed buffer size for hexadecimal conversion
        bytes memory converted = new bytes(buffer.length * 2);

        bytes memory _base = "0123456789abcdef";

        for (uint256 i = 0; i < buffer.length; i++) {
            converted[i * 2] = _base[uint8(buffer[i]) / _base.length];
            converted[i * 2 + 1] = _base[uint8(buffer[i]) % _base.length];
        }

        return string(abi.encodePacked("0x", converted));
    }
}
