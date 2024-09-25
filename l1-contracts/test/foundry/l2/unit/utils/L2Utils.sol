// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    address internal constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);

    string internal constant L2_ASSET_ROUTER_PATH = "./zkout/L2AssetRouter.sol/L2AssetRouter.json";
    string internal constant L2_NATIVE_TOKEN_VAULT_PATH = "./zkout/L2NativeTokenVault.sol/L2NativeTokenVault.json";

    /// @notice Returns the bytecode of a given era contract from a `zkout` folder.
    function readEraBytecode(string memory _filename) internal returns (bytes memory bytecode) {
        string memory artifact = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat("./zkout/", _filename, ".sol/", _filename, ".json")
        );

        bytecode = vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    /// @notice Returns the bytecode of a given system contract.
    function readSystemContractsBytecode(string memory _filename) internal view returns (bytes memory) {
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/",
                _filename,
                ".sol/",
                _filename,
                ".json"
            )
        );
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
    }

    /**
     * @dev Initializes the system contracts.
     * @dev It is a hack needed to make the tests be able to call system contracts directly.
     */
    function initSystemContracts() internal {
        bytes memory contractDeployerBytecode = readSystemContractsBytecode("ContractDeployer");
        vm.etch(DEPLOYER_SYSTEM_CONTRACT, contractDeployerBytecode);
    }

    /// @notice Deploys the L2AssetRouter contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _eraChainId The chain ID of the era chain.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    function forceDeployAssetRouter(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1AssetRouter,
        address _legacySharedBridge
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2AssetRouter(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner);
        }

        bytes memory bytecode = readEraBytecode("L2AssetRouter");

        bytes32 bytecodehash = L2ContractHelper.hashL2Bytecode(bytecode);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: bytecodehash,
            newAddress: L2_ASSET_ROUTER_ADDR,
            callConstructor: true,
            value: 0,
            input: abi.encode(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner)
        });

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses(deployments);
    }

    /// @notice Deploys the L2NativeTokenVault contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _aliasedOwner The address of the aliased owner.
    /// @param _l2TokenProxyBytecodeHash The hash of the L2 token proxy bytecode.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    /// @param _l2TokenBeacon The address of the L2 token beacon.
    /// @param _contractsDeployedAlready Whether the contracts are deployed already.
    function forceDeployNativeTokenVault(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _l2TokenBeacon,
        bool _contractsDeployedAlready
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2NativeTokenVault({
                _l1ChainId: _l1ChainId,
                _aliasedOwner: _aliasedOwner,
                _l2TokenProxyBytecodeHash: _l2TokenProxyBytecodeHash,
                _legacySharedBridge: _legacySharedBridge,
                _bridgedTokenBeacon: _l2TokenBeacon,
                _contractsDeployedAlready: _contractsDeployedAlready,
                _wethToken: address(0),
                _baseTokenAssetId: ethAssetId
            });
        }

        bytes memory bytecode = readEraBytecode("L2NativeTokenVault");

        bytes32 bytecodehash = L2ContractHelper.hashL2Bytecode(bytecode);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: bytecodehash,
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDR,
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                _l1ChainId,
                _aliasedOwner,
                _l2TokenProxyBytecodeHash,
                _legacySharedBridge,
                _l2TokenBeacon,
                _contractsDeployedAlready,
                address(0),
                ethAssetId
            )
        });

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses(deployments);
    }

    function deploySharedBridgeLegacy(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash
    ) internal returns (address) {
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);

        L2SharedBridgeLegacy bridge = new L2SharedBridgeLegacy();
        console.log("bridge", address(bridge));
        address proxyAdmin = address(0x1);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(bridge),
            proxyAdmin,
            abi.encodeWithSelector(
                L2SharedBridgeLegacy.initialize.selector,
                _l1SharedBridge,
                _l2TokenProxyBytecodeHash,
                _aliasedOwner
            )
        );
        console.log("proxy", address(proxy));
        return address(proxy);
    }

    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }
}
