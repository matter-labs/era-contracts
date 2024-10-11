// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils} from "./../Utils.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {DummyL1ERC20Bridge} from "contracts/dev-contracts/DummyL1ERC20Bridge.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

/// This scripts is only for developer
contract SetupLegacyBridge is Script {
    using stdToml for string;

    Config internal config;
    Addresses internal addresses;

    struct Config {
        uint256 chainId;
        address l2SharedBridgeAddress;
        bytes32 create2FactorySalt;
    }

    struct Addresses {
        address create2FactoryAddr;
        address bridgehub;
        address diamondProxy;
        address sharedBridgeProxy;
        address transparentProxyAdmin;
        address erc20BridgeProxy;
        address tokenWethAddress;
        address erc20BridgeProxyImpl;
        address sharedBridgeProxyImpl;
    }

    function run() public {
        initializeConfig();
        deploySharedBridgeImplementation();
        upgradeImplementation(addresses.sharedBridgeProxy, addresses.sharedBridgeProxyImpl);
        deployDummyErc20Bridge();
        upgradeImplementation(addresses.erc20BridgeProxy, addresses.erc20BridgeProxyImpl);
        setParamsForDummyBridge();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/setup-legacy-bridge.toml");
        string memory toml = vm.readFile(path);

        addresses.bridgehub = toml.readAddress("$.bridgehub");
        addresses.diamondProxy = toml.readAddress("$.diamond_proxy");
        addresses.sharedBridgeProxy = toml.readAddress("$.shared_bridge_proxy");
        addresses.transparentProxyAdmin = toml.readAddress("$.transparent_proxy_admin");
        addresses.erc20BridgeProxy = toml.readAddress("$.erc20bridge_proxy");
        addresses.tokenWethAddress = toml.readAddress("$.token_weth_address");
        addresses.create2FactoryAddr = toml.readAddress("$.create2factory_addr");
        config.chainId = toml.readUint("$.chain_id");
        config.l2SharedBridgeAddress = toml.readAddress("$.l2shared_bridge_address");
        config.create2FactorySalt = toml.readBytes32("$.create2factory_salt");
    }

    // We need to deploy new shared bridge for changing chain id and diamond proxy address
    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1SharedBridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.tokenWethAddress, addresses.bridgehub, config.chainId, addresses.diamondProxy)
        );

        address contractAddress = deployViaCreate2(bytecode);
        addresses.sharedBridgeProxyImpl = contractAddress;
    }

    function deployDummyErc20Bridge() internal {
        bytes memory bytecode = abi.encodePacked(
            type(DummyL1ERC20Bridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.sharedBridgeProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        addresses.erc20BridgeProxyImpl = contractAddress;
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
        (address l2TokenBeacon, bytes32 l2TokenBeaconHash) = calculateTokenBeaconAddress();
        DummyL1ERC20Bridge bridge = DummyL1ERC20Bridge(addresses.erc20BridgeProxy);
        vm.broadcast();
        bridge.setValues(config.l2SharedBridgeAddress, l2TokenBeacon, l2TokenBeaconHash);
    }

    function calculateTokenBeaconAddress()
        internal
        returns (address tokenBeaconAddress, bytes32 tokenBeaconBytecodeHash)
    {
        bytes memory l2StandardTokenCode = L2ContractsBytecodesLib.readStandardERC20Bytecode();
        (address l2StandardToken, ) = calculateL2Create2Address(
            config.l2SharedBridgeAddress,
            l2StandardTokenCode,
            bytes32(0),
            ""
        );

        bytes memory beaconProxy = L2ContractsBytecodesLib.readBeaconProxyBytecode();
        tokenBeaconBytecodeHash = L2ContractHelper.hashL2Bytecode(beaconProxy);

        bytes memory upgradableBeacon = L2ContractsBytecodesLib.readUpgradeableBeaconBytecode();

        (tokenBeaconAddress, ) = calculateL2Create2Address(
            config.l2SharedBridgeAddress,
            upgradableBeacon,
            bytes32(0),
            abi.encode(l2StandardToken)
        );
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
