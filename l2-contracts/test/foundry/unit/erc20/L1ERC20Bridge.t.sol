// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {Script, console2 as console} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";

import {L2StandardERC20} from "contracts/bridge/L2StandardERC20.sol";
import {L2AssetRouter}  from "contracts/bridge/L2AssetRouter.sol";

import { IContractDeployer, DEPLOYER_SYSTEM_CONTRACT, L2ContractHelper, L2_ASSET_ROUTER } from "contracts/L2ContractHelper.sol";


contract SomeOtherContract {
    constructor() {

    }
}

library Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    address constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);

    string internal constant L2_ASSET_ROUTER_PATH = "./zkout/L2AssetRouter.sol/L2AssetRouter.json"; 

    function readEraBytecode(string memory _path) internal returns (bytes memory bytecode) {
        string memory artifact = vm.readFile(_path);
        bytecode = vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    function forceDeployAssetRouter(
        uint256 _l1ChainId, uint256 _eraChainId, address _l1AssetRouter, address _legacySharedBridge
    ) internal {
        // to ensure that the bytecode is known
        {
            L2AssetRouter dummy = new L2AssetRouter(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge);
            bytes32 myhash;
            assembly {
                myhash := extcodehash(dummy)
            }
            console.logBytes32(myhash);
        }

        bytes memory bytecode = readEraBytecode(L2_ASSET_ROUTER_PATH);

        bytes32 bytecodehash = L2ContractHelper.hashL2BytecodeMemory(bytecode);
        console.logBytes32(bytecodehash);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2BytecodeMemory(bytecode),
            newAddress: address(L2_ASSET_ROUTER),
            callConstructor: true,
            value: 0,
            input: abi.encode(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge)
        });

        // console.log(IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).getNewAddressCreate2(address(0), bytes32(0), bytes32(0), new bytes(0)));

        // vm.zkVm(true);
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses(
            deployments
        );
    }
}

contract L1Erc20BridgeTest is Test {
    // L1ERC20Bridge internal bridge;

    // ReenterL1ERC20Bridge internal reenterL1ERC20Bridge;
    // L1ERC20Bridge internal bridgeReenterItself;

    // TestnetERC20Token internal token;
    // TestnetERC20Token internal feeOnTransferToken;
    // address internal randomSigner;
    // address internal alice;
    // address sharedBridgeAddress;

    constructor() {
        // randomSigner = makeAddr("randomSigner");
        // alice = makeAddr("alice");

        // sharedBridgeAddress = makeAddr("shared bridge");
        // bridge = new L1ERC20Bridge(IL1SharedBridge(sharedBridgeAddress));

        // reenterL1ERC20Bridge = new ReenterL1ERC20Bridge();
        // bridgeReenterItself = new L1ERC20Bridge(IL1SharedBridge(address(reenterL1ERC20Bridge)));
        // reenterL1ERC20Bridge.setBridge(bridgeReenterItself);

        // token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        // feeOnTransferToken = new FeeOnTransferToken("FeeOnTransferToken", "FOT", 18);
        // token.mint(alice, type(uint256).max);
        // feeOnTransferToken.mint(alice, type(uint256).max);
    }

    // add this to be excluded from coverage report
    // function test() internal virtual {}

    function test_Stuff() public {
        Utils.forceDeployAssetRouter(9, 9, address(1), address(0));
    }
}
