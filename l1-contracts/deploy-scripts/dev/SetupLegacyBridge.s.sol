// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils} from "./../Utils.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {PermanentValuesHelper} from "../utils/PermanentValuesHelper.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {DummyL1ERC20Bridge} from "contracts/dev-contracts/DummyL1ERC20Bridge.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {ISetupLegacyBridge} from "contracts/script-interfaces/ISetupLegacyBridge.sol";

/// This scripts is only for developer
contract SetupLegacyBridge is Script, ISetupLegacyBridge {
    using stdToml for string;

    Config internal config;
    SetupLegacyBridgeAddresses internal addresses;

    struct Config {
        uint256 chainId;
        bytes32 create2FactorySalt;
    }

    struct SetupLegacyBridgeAddresses {
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

    function run(address _bridgehub, uint256 _chainId) public {
        initializeConfig(_bridgehub, _chainId);
        deploySharedBridgeImplementation();
        upgradeImplementation(addresses.sharedBridgeProxy, addresses.sharedBridgeProxyImpl);
        deployDummyErc20Bridge();
        upgradeImplementation(addresses.proxies.erc20Bridge, addresses.proxies.erc20BridgeImpl);
        setParamsForDummyBridge();
        deployL1NullifierImplementation();
        upgradeImplementation(addresses.l1Nullifier, addresses.proxies.l1NullifierImpl);
    }

    function initializeConfig(address bridgehub, uint256 chainId) internal {
        addresses.bridgehub = bridgehub;
        config.chainId = chainId;

        // Query diamond proxy from bridgehub using chain ID
        addresses.diamondProxy = IL1Bridgehub(bridgehub).getZKChain(chainId);

        // Read create2 factory parameters from permanent-values.toml
        (address create2FactoryAddr, bytes32 create2FactorySalt) = PermanentValuesHelper.getPermanentValues(vm);
        addresses.create2FactoryAddr = create2FactoryAddr;
        config.create2FactorySalt = create2FactorySalt;

        // Use AddressIntrospector to get addresses from deployed contracts
        BridgehubAddresses memory bhAddresses = AddressIntrospector.getBridgehubAddresses(IL1Bridgehub(bridgehub));
        addresses.l1Nullifier = bhAddresses.assetRouterAddresses.l1Nullifier;
        addresses.sharedBridgeProxy = bhAddresses.assetRouter;
        addresses.l1NativeTokenVault = bhAddresses.assetRouterAddresses.nativeTokenVault;
        addresses.transparentProxyAdmin = bhAddresses.transparentProxyAdmin;
        addresses.tokenWethAddress = bhAddresses.assetRouterAddresses.l1WethToken;
        addresses.proxies.erc20Bridge = AddressIntrospector.getLegacyBridgeAddress(bhAddresses.assetRouter);
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
        addresses.proxies.erc20BridgeImpl = contractAddress;
    }

    function deployL1NullifierImplementation() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub);

        bytes memory bytecode = abi.encodePacked(
            type(L1NullifierDev).creationCode,
            abi.encode(
                addresses.bridgehub,
                bridgehub.messageRoot(),
                // This value ignored now, but supposed to be interop center
                address(0),
                config.chainId,
                addresses.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);

        addresses.proxies.l1NullifierImpl = contractAddress;
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
                addresses.proxies.erc20Bridge,
                addresses.l1Nullifier,
                Ownable2StepUpgradeable(addresses.l1Nullifier).owner()
            );

        address l2LegacySharedBridgeAddress = L2LegacySharedBridgeTestHelper.calculateL2LegacySharedBridgeProxyAddr(
            addresses.proxies.erc20Bridge,
            addresses.l1Nullifier,
            Ownable2StepUpgradeable(addresses.l1Nullifier).owner()
        );

        DummyL1ERC20Bridge bridge = DummyL1ERC20Bridge(addresses.proxies.erc20Bridge);
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
