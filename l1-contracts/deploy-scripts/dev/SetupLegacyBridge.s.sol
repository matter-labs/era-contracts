// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils} from "./../Utils.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {DummyL1ERC20Bridge} from "contracts/dev-contracts/DummyL1ERC20Bridge.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L2LegacySharedBridgeTestHelper} from "../L2LegacySharedBridgeTestHelper.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

/// This scripts is only for developer
contract SetupLegacyBridge is Script {
    using stdToml for string;

    Config internal config;
    Addresses internal addresses;

    struct Config {
        uint256 chainId;
        bytes32 create2FactorySalt;
    }

    struct Addresses {
        address create2FactoryAddr;
        address bridgehub;
        address l1Nullifier;
        address diamondProxy;
        address sharedBridgeProxy;
        address l1NativeTokenVault;
        address transparentProxyAdmin;
        address erc20BridgeProxy;
        address tokenWethAddress;
        address erc20BridgeProxyImpl;
        address sharedBridgeProxyImpl;
        address l1NullifierProxyImpl;
    }

    function run() public {
        initializeConfig();
        deploySharedBridgeImplementation();
        upgradeImplementation(addresses.sharedBridgeProxy, addresses.sharedBridgeProxyImpl);
        deployDummyErc20Bridge();
        upgradeImplementation(addresses.erc20BridgeProxy, addresses.erc20BridgeProxyImpl);
        setParamsForDummyBridge();
        deployL1NullifierImplementation();
        upgradeImplementation(addresses.l1Nullifier, addresses.l1NullifierProxyImpl);
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/setup-legacy-bridge.toml");
        string memory toml = vm.readFile(path);

        addresses.bridgehub = toml.readAddress("$.bridgehub");
        addresses.diamondProxy = toml.readAddress("$.diamond_proxy");
        addresses.l1Nullifier = toml.readAddress("$.l1_nullifier_proxy");
        addresses.sharedBridgeProxy = toml.readAddress("$.shared_bridge_proxy");
        addresses.l1NativeTokenVault = toml.readAddress("$.l1_native_token_vault");
        addresses.transparentProxyAdmin = toml.readAddress("$.transparent_proxy_admin");
        addresses.erc20BridgeProxy = toml.readAddress("$.erc20bridge_proxy");
        addresses.tokenWethAddress = toml.readAddress("$.token_weth_address");
        addresses.create2FactoryAddr = toml.readAddress("$.create2factory_addr");
        config.chainId = toml.readUint("$.chain_id");
        config.create2FactorySalt = toml.readBytes32("$.create2factory_salt");
    }

    // We need to deploy new shared bridge for changing chain id and diamond proxy address
    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1AssetRouter).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                addresses.tokenWethAddress,
                addresses.bridgehub,
                addresses.l1Nullifier,
                config.chainId,
                addresses.diamondProxy
            )
        );

        address contractAddress = deployViaCreate2(bytecode);
        addresses.sharedBridgeProxyImpl = contractAddress;
    }

    function deployDummyErc20Bridge() internal {
        bytes memory bytecode = abi.encodePacked(
            type(DummyL1ERC20Bridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.l1Nullifier, addresses.sharedBridgeProxy, addresses.l1NativeTokenVault, config.chainId)
        );
        address contractAddress = deployViaCreate2(bytecode);
        addresses.erc20BridgeProxyImpl = contractAddress;
    }

    function deployL1NullifierImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1NullifierDev).creationCode,
            abi.encode(addresses.bridgehub, config.chainId, addresses.diamondProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);

        addresses.l1NullifierProxyImpl = contractAddress;
    }

    function upgradeImplementation(address proxy, address implementation) internal {
        bytes memory proxyAdminUpgradeData = abi.encodeCall(
            ProxyAdmin.upgrade,
            (ITransparentUpgradeableProxy(proxy), implementation)
        );
        ProxyAdmin _proxyAdmin = ProxyAdmin(addresses.transparentProxyAdmin);
        address governance = _proxyAdmin.owner();

        Utils.executeUpgrade({
            _governor: address(governance),
            _salt: bytes32(0),
            _target: address(addresses.transparentProxyAdmin),
            _data: proxyAdminUpgradeData,
            _value: 0,
            _delay: 0
        });
    }

    function setParamsForDummyBridge() internal {
        (address l2TokenBeacon, bytes32 l2TokenBeaconProxyHash) = L2LegacySharedBridgeTestHelper
            .calculateTestL2TokenBeaconAddress(
                addresses.erc20BridgeProxy,
                addresses.l1Nullifier,
                Ownable2StepUpgradeable(addresses.l1Nullifier).owner()
            );

        address l2LegacySharedBridgeAddress = L2LegacySharedBridgeTestHelper.calculateL2LegacySharedBridgeProxyAddr(
            addresses.erc20BridgeProxy,
            addresses.l1Nullifier,
            Ownable2StepUpgradeable(addresses.l1Nullifier).owner()
        );

        DummyL1ERC20Bridge bridge = DummyL1ERC20Bridge(addresses.erc20BridgeProxy);
        vm.broadcast();
        bridge.setValues(l2LegacySharedBridgeAddress, l2TokenBeacon, l2TokenBeaconProxyHash);
    }

    function calculateL2Create2Address(
        address sender,
        bytes memory bytecode,
        bytes32 create2salt,
        bytes memory constructorargs
    ) internal returns (address create2Address, bytes32 bytecodeHash) {
        bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        create2Address = L2ContractHelper.computeCreate2Address(
            sender,
            create2salt,
            bytecodeHash,
            keccak256(constructorargs)
        );
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.create2FactorySalt, addresses.create2FactoryAddr);
    }
}
