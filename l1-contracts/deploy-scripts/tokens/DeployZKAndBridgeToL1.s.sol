// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
// solhint-disable no-unused-import

import {
    L2_ASSET_ROUTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {FinalizeL1DepositParams} from "contracts/common/Messaging.sol";
import {IL1InteropHandler} from "contracts/bridge/interfaces/IL1InteropHandler.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {Utils} from "../utils/Utils.sol";
import {MintFailed} from "../utils/ZkSyncScriptErrors.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {BridgesDeployedAddresses} from "../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

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

    function run(address _bridgehub, uint256 _chainId) public {
        initializeConfig(_bridgehub, _chainId);
        deployZkToken();
        saveOutput();
    }

    function getTokenAddress() public view returns (address) {
        return config.zkToken.addr;
    }

    function initializeConfig(address bridgehub, uint256 chainId) internal {
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

        // Use AddressIntrospector to get addresses from deployed contracts
        config.bridgehub = bridgehub;
        address assetRouter = address(IL1Bridgehub(bridgehub).assetRouter());
        BridgesDeployedAddresses memory bridges = AddressIntrospector.getBridgesDeployedAddresses(assetRouter);
        config.l1SharedBridge = assetRouter;
        config.l1Nullifier = bridges.proxies.l1Nullifier;
        config.chainId = chainId;

        // Grab config from custom config file
        path = string.concat(root, vm.envString("ZK_CHAIN_CONFIG"));
        toml = vm.readFile(path);
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

        // The ZK-token L2->L1 withdrawal now goes through the InteropCenter as a single-call bundle to
        // the L1 asset router (the unified path that replaced L2AssetRouter.withdraw). The deployer
        // approved the NTV above; the withdrawn amount rides in the bridge-burn transfer data.
        uint256 l1ChainId = l2AR.L1_CHAIN_ID();
        bytes memory zkTransferData = DataEncoding.encodeBridgeBurnData(someBigAmount, deployer, zkTokenAddress);
        vm.broadcast();
        // slither-disable-next-line unused-return
        IInteropCenter(L2_INTEROP_CENTER_ADDR).sendBundle(
            InteroperableAddress.formatEvmV1(l1ChainId),
            DataEncoding.encodeInteropWithdrawalCallStarters(zkTokenAssetId, zkTransferData),
            new bytes[](0)
        );
        uint256 deployerBalanceAfterWithdraw = zkToken.balanceOf(deployer);
        console.log("Deployed balance after withdraw:", deployerBalanceAfterWithdraw);
    }

    /// TODO(EVM-748): make that function support non-ETH based chains
    function supplyEraWallet(address _bridgehub, uint256 _chainId, address addr, uint256 amount) public {
        initializeConfig(_bridgehub, _chainId);

        Utils.runL1L2Transaction(
            hex"",
            Utils.MAX_PRIORITY_TX_GAS,
            amount,
            new bytes[](0),
            addr,
            config.chainId,
            config.bridgehub,
            config.l1SharedBridge,
            msg.sender
        );
    }

    function finalizeZkTokenWithdrawal(
        address _bridgehub,
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes memory _message,
        bytes32[] memory _merkleProof
    ) public {
        initializeConfig(_bridgehub, _chainId);

        L1Nullifier l1Nullifier = L1Nullifier(config.l1Nullifier);
        IL1InteropHandler l1InteropHandler = IL1InteropHandler(l1Nullifier.l1InteropHandler());

        vm.broadcast();
        l1InteropHandler.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: _chainId,
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2Sender: L2_INTEROP_CENTER_ADDR,
                l2TxNumberInBatch: _l2TxNumberInBatch,
                message: _message,
                merkleProof: _merkleProof
            })
        );
    }

    function saveL1Address(address _bridgehub, uint256 _chainId) public {
        initializeConfig(_bridgehub, _chainId);
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

    function fundChainGovernor(address _bridgehub, uint256 _chainId) public {
        initializeConfig(_bridgehub, _chainId);

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
