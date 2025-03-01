// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

import {L2SharedBridgeV25} from "./test/v25/L2SharedBridgeV25.sol";
import {L2SharedBridgeLegacy} from "../bridge/L2SharedBridgeLegacy.sol";
import {SystemContractsHelper} from "./SystemContractsHelper.sol";
import {L2ContractHelper, IContractDeployer} from "../common/libraries/L2ContractHelper.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BridgedStandardERC20} from "../bridge/BridgedStandardERC20.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";

/// Test for the compatibility for legacy bridged tokens.
/// To set up the asset router correctly, we'll need to delegatecall the `ComplexUpgrader`
/// to this implementation
contract LegacySharedBridgeTest {
    address l2TokenAddress;
    address aliasedL1SharedBridge;
    
    function _getBytecodeHash(address _addr) internal view returns (bytes32 result) {
        assembly {
            result := extcodehash(_addr)
        }
    }

    // Unfortunately we can not import `TransparentUpgradeableProxy` as for some reason it would modify the
    // bytecode hash of the Bridgehub. This will be fixed in the future versions of the foundry-zksync.
    // This is why this function uses `abi.encodeWithSignature`
    function _forceUpgradeProxy(address proxy, address upgradeTo, bytes memory data) internal {
        // We assume that the admin of the proxy has address 0.
        address admin = address(0);

        if (data.length == 0) {
            (bool success, ) = SystemContractsHelper.mimicCall(
                proxy,
                admin,
                // Unfortunately we can not import `Tr
                abi.encodeWithSignature(
                    "upgradeTo(address)",
                    upgradeTo
                )
            );
            require(success, "Failed to finalize legacy bridging");
        } else {
            (bool success, ) = SystemContractsHelper.mimicCall(
                proxy,
                admin,
                abi.encodeWithSignature(
                    "upgradeToAndCall(address,bytes)",
                    upgradeTo,
                    data
                )
            );
            require(success, "Failed to finalize legacy bridging");
        }
    }

    function resetLegacyParams(
        uint256 l1ChainId,
        address legacyL1Token,
        address l1SharedBridge,
        bytes32 beaconProxyBytecodeHash,
        address l2SharedProxyProxyAddr
    ) external {
        // We need to firstly deploy the legacy bridge.
        //
        // Using dummy era chain id to ensure all the necessary contracts will be deployed
        // during initialization.

        uint256 dummyEraChainId = 2;

        L2SharedBridgeV25 impl = new L2SharedBridgeV25(dummyEraChainId);

        _forceUpgradeProxy(
            l2SharedProxyProxyAddr,
            address(impl),
            abi.encodeCall(
                L2SharedBridgeV25.initialize,
                (l1SharedBridge, address(0), beaconProxyBytecodeHash, address(this))
            )
        );

        // Now, we need to try and deposit it
        (bool success, ) = SystemContractsHelper.mimicCall(
            l2SharedProxyProxyAddr,
            AddressAliasHelper.applyL1ToL2Alias(l1SharedBridge),
            abi.encodeCall(
                L2SharedBridgeV25.finalizeDeposit,
                (
                    // The l1 sender / l2 receiver do not matter much
                    address(uint160(0xffffffff)),
                    address(uint160(0xffffffff)),
                    legacyL1Token,
                    uint256(0xffffffff),
                    abi.encode(abi.encode(string("name")), abi.encode(string("symbol")), abi.encode(uint8(18)))
                )
            )
        );
        require(success, "Failed to finalize legacy bridging");

        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(l1ChainId, ETH_TOKEN_ADDRESS);

        // Now, we need to ensure that the L2NativeTokenVault/L2AssetRouter are aware of the new bridge.
        IContractDeployer.ForceDeployment[] memory forceDeployments = new IContractDeployer.ForceDeployment[](2);

        // To not accidentally change them, we will query those from storage
        bytes32 l2AssetRouterBytecodeHash = _getBytecodeHash(L2_ASSET_ROUTER_ADDR);
        bytes32 l2NativeTokenVaultBytecodeHash = _getBytecodeHash(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Configure the AssetRouter deployment.
        forceDeployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: l2AssetRouterBytecodeHash,
            newAddress: address(L2_ASSET_ROUTER_ADDR),
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                l1ChainId,
                dummyEraChainId,
                // In the real upgrade, the L1 asset router differs from the old L1 shared bridge, but
                // in this case, it is okay.
                l1SharedBridge,
                l2SharedProxyProxyAddr,
                baseTokenAssetId,
                address(this)
            )
        });

        // Configure the Native Token Vault deployment.
        forceDeployments[1] = IContractDeployer.ForceDeployment({
            bytecodeHash: l2NativeTokenVaultBytecodeHash,
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDR,
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                l1ChainId,
                address(this),
                beaconProxyBytecodeHash,
                l2SharedProxyProxyAddr,
                address(L2SharedBridgeV25(l2SharedProxyProxyAddr).l2TokenBeacon()),
                true,
                address(0),
                baseTokenAssetId
            )
        });

        IContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(forceDeployments);

        // Saving the result for future usage in the test.
        l2TokenAddress = L2SharedBridgeV25(l2SharedProxyProxyAddr).l2TokenAddress(legacyL1Token);
        aliasedL1SharedBridge = AddressAliasHelper.applyL1ToL2Alias(l1SharedBridge);

        // Now, we also need to upgrade the legacy bridge to the v26 version
        L2SharedBridgeLegacy newImpl = new L2SharedBridgeLegacy();
        _forceUpgradeProxy(l2SharedProxyProxyAddr, address(newImpl), bytes(""));

        BridgedStandardERC20 bridgedERC20Impl = new BridgedStandardERC20();
        UpgradeableBeacon beacon = L2SharedBridgeLegacy(l2SharedProxyProxyAddr).l2TokenBeacon();
        beacon.upgradeTo(address(bridgedERC20Impl));
    }
}
