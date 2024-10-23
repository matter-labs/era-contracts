// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Vm} from "forge-std/Vm.sol";
import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
// solhint-disable no-unused-import
import {WETH9} from "contracts/dev-contracts/WETH9.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {Utils} from "./Utils.sol";
import {MintFailed} from "./ZkSyncScriptErrors.sol";

contract DeployZKScript is Script {
    using stdToml for string;

    struct Config {
        TokenDescription zkToken;
        address deployerAddress;
        address[] additionalAddressesForMinting;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
        uint256 chainId;
        address l1SharedBridge;
        address bridgehub;
        address l1Nullifier;
        address chainAdmin;
        address governance;
        address deployer;
        address owner;
        address anotherOwner;
        address chainGovernor;
    }

    struct TokenDescription {
        address addr;
        string name;
        string symbol;
        uint256 decimals;
        string implementation;
        uint256 mint;
        bytes32 assetId;
    }

    Config internal config;

    function run() public {
        initializeConfig();
        deployZkToken();
        saveOutput();
    }

    function getTokenAddress() public view returns (address) {
        return config.zkToken.addr;
    }

    function initializeConfig() internal {
        config.deployerAddress = msg.sender;

        string memory root = vm.projectRoot();

        // Grab config from output of l1 deployment
        string memory path = string.concat(root, vm.envString("TOKENS_CONFIG"));
        string memory toml = vm.readFile(path);

        config.additionalAddressesForMinting = vm.parseTomlAddressArray(toml, "$.additional_addresses_for_minting");

        // Parse the ZK token configuration
        string memory key = "$.tokens.ZK";
        config.zkToken.name = toml.readString(string.concat(key, ".name"));
        config.zkToken.symbol = toml.readString(string.concat(key, ".symbol"));
        config.zkToken.decimals = toml.readUint(string.concat(key, ".decimals"));
        config.zkToken.implementation = toml.readString(string.concat(key, ".implementation"));
        config.zkToken.mint = toml.readUint(string.concat(key, ".mint"));

        // Grab config from custom config file
        path = string.concat(root, vm.envString("ZK_CHAIN_CONFIG"));
        toml = vm.readFile(path);

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.l1SharedBridge = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        config.l1Nullifier = toml.readAddress("$.deployed_addresses.bridges.l1_nullifier_proxy_addr");
        config.chainId = toml.readUint("$.chain.chain_chain_id");
        config.chainGovernor = toml.readAddress("$.owner_address");
    }

    function initializeAdditionalConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT"));
        string memory toml = vm.readFile(path);

        config.owner = toml.readAddress("$.owner_address");
    }

    function deployZkToken() internal {
        uint256 someBigAmount = 100000000000000000000000000000000;
        TokenDescription storage token = config.zkToken;
        console.log("Deploying token:", token.name);

        vm.startBroadcast();
        address zkTokenAddress = deployErc20({
            name: token.name,
            symbol: token.symbol,
            decimals: token.decimals,
            mint: token.mint,
            additionalAddressesForMinting: config.additionalAddressesForMinting
        });
        console.log("Token deployed at:", zkTokenAddress);
        token.addr = zkTokenAddress;
        address deployer = msg.sender;
        TestnetERC20Token zkToken = TestnetERC20Token(zkTokenAddress);
        zkToken.mint(deployer, someBigAmount);
        uint256 deployerBalance = zkToken.balanceOf(deployer);
        console.log("Deployer balance:", deployerBalance);
        L2AssetRouter l2AR = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        L2NativeTokenVault l2NTV = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        l2NTV.registerToken(zkTokenAddress);
        bytes32 zkTokenAssetId = l2NTV.assetId(zkTokenAddress);
        config.zkToken.assetId = zkTokenAssetId;
        console.log("zkTokenAssetId:", uint256(zkTokenAssetId));
        zkToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, someBigAmount);
        vm.stopBroadcast();

        vm.broadcast();
        l2AR.withdraw(zkTokenAssetId, abi.encode(someBigAmount, deployer));
        uint256 deployerBalanceAfterWithdraw = zkToken.balanceOf(deployer);
        console.log("Deployed balance after withdraw:", deployerBalanceAfterWithdraw);
    }

    /// TODO(EVM-748): make that function support non-ETH based chains
    function supplyEraWallet(address addr, uint256 amount) public {
        initializeConfig();

        Utils.runL1L2Transaction(
            hex"",
            Utils.MAX_PRIORITY_TX_GAS,
            amount,
            new bytes[](0),
            addr,
            config.chainId,
            config.bridgehub,
            config.l1SharedBridge
        );
    }

    function finalizeZkTokenWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes memory _message,
        bytes32[] memory _merkleProof
    ) public {
        initializeConfig();

        L1Nullifier l1Nullifier = L1Nullifier(config.l1Nullifier);

        vm.broadcast();
        l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: _chainId,
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: _l2TxNumberInBatch,
                message: _message,
                merkleProof: _merkleProof
            })
        );
    }

    function saveL1Address() public {
        initializeConfig();
        initializeAdditionalConfig();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("ZK_TOKEN_OUTPUT"));

        string memory toml = vm.readFile(path);

        bytes32 zkTokenAssetId = toml.readBytes32("$.ZK.assetId");

        L1AssetRouter l1AR = L1AssetRouter(config.l1SharedBridge);
        console.log("L1 AR address", address(l1AR));
        IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(address(l1AR.nativeTokenVault()));
        address l1ZKAddress = nativeTokenVault.tokenAddress(zkTokenAssetId);
        console.log("L1 ZK address", l1ZKAddress);
        TestnetERC20Token l1ZK = TestnetERC20Token(l1ZKAddress);

        uint256 balance = l1ZK.balanceOf(config.deployerAddress);
        vm.broadcast();
        l1ZK.transfer(config.owner, balance / 2);
        string memory tokenInfo = vm.serializeAddress("ZK", "l1Address", l1ZKAddress);
        vm.writeToml(tokenInfo, path, ".ZK.l1Address");
    }

    function fundChainGovernor() public {
        initializeConfig();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("ZK_TOKEN_OUTPUT"));
        string memory toml = vm.readFile(path);

        address l1ZKAddress = toml.readAddress("$.ZK.l1Address.l1Address");
        console.log("L1 ZK address: ", l1ZKAddress);
        console.log("Address of governor: ", config.chainGovernor);
        TestnetERC20Token l1ZK = TestnetERC20Token(l1ZKAddress);
        uint256 balance = l1ZK.balanceOf(config.deployerAddress);
        vm.broadcast();
        l1ZK.transfer(config.chainGovernor, balance / 10);
    }

    function deployErc20(
        string memory name,
        string memory symbol,
        uint256 decimals,
        uint256 mint,
        address[] storage additionalAddressesForMinting
    ) internal returns (address) {
        address tokenAddress = address(new TestnetERC20Token(name, symbol, uint8(decimals))); // No salt for testing

        if (mint > 0) {
            additionalAddressesForMinting.push(config.deployerAddress);
            uint256 addressMintListLength = additionalAddressesForMinting.length;
            for (uint256 i = 0; i < addressMintListLength; ++i) {
                (bool success, ) = tokenAddress.call(
                    abi.encodeWithSignature("mint(address,uint256)", additionalAddressesForMinting[i], mint)
                );
                if (!success) {
                    revert MintFailed();
                }
                console.log("Minting to:", additionalAddressesForMinting[i]);
                if (!success) {
                    revert MintFailed();
                }
            }
        }

        return tokenAddress;
    }

    function saveOutput() internal {
        TokenDescription memory token = config.zkToken;
        string memory section = token.symbol;

        // Serialize each attribute directly under the token's symbol (e.g., [ZK])
        vm.serializeString(section, "name", token.name);
        vm.serializeString(section, "symbol", token.symbol);
        vm.serializeUint(section, "decimals", token.decimals);
        vm.serializeString(section, "implementation", token.implementation);
        vm.serializeUintToHex(section, "mint", token.mint);
        vm.serializeBytes32(section, "assetId", token.assetId);
        vm.serializeAddress(token.symbol, "l1Address", address(0));

        string memory tokenInfo = vm.serializeAddress(token.symbol, "address", token.addr);
        string memory toml = vm.serializeString("root", "ZK", tokenInfo);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("ZK_TOKEN_OUTPUT"));
        vm.writeToml(toml, path);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
