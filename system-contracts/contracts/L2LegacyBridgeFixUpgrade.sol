


// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {L2_NATIVE_TOKEN_VAULT, L2_ASSET_ROUTER, L2_BRIDGE_HUB} from "./Constants.sol";

import {IBridgedStandardERC20} from "./interfaces/IBridgedStandardERC20.sol";

/// @dev Storage slot with the admin of the contract used for EIP1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @dev Storage slot with the implementation of the contract used for EIP1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2LegacyBridgeFixUpgrade
contract L2LegacyBridgeFixUpgrade {
    /// @notice Initializes the `L2GatewayUpgrade` contract.
    /// @dev This constructor is intended to be delegate-called by the `ComplexUpgrader` contract.
    function upgrade(
        address _aliasedGovernance,
        bytes32 _bridgedEthAssetId
    ) external { 
        // Firstly, we ensure that the governor address is correct for all the predeployed system contracts.
        // This should be already the case on mainnet and testnet. However, on a closed staging environment this is not
        // the case due to how v26 upgrade has been performed.
        // To ensure that the same codebase is used everwhere, we include this patch here as well.
        ensureOwnable2StepOwner(address(L2_BRIDGE_HUB), _aliasedGovernance);
        ensureOwnable2StepOwner(address(L2_ASSET_ROUTER), _aliasedGovernance);
        ensureOwnable2StepOwner(address(L2_NATIVE_TOKEN_VAULT), _aliasedGovernance);

        // Now, we need to patch the governance for the L2 legacy shared bridge as well as fix the 
        // the metadata for bridged ETH token.

        address l2LegacySharedBridge = L2_ASSET_ROUTER.L2_LEGACY_SHARED_BRIDGE();
        if (l2LegacySharedBridge == address(0)) {
            // This chain does not legacy L2 shared bridge, which means that there is no governance to upgrade
            // as well as that the ETH-token bug was not present there.
            return;
        }

        migrateSharedBridgeLegacyOwner(l2LegacySharedBridge, _aliasedGovernance);
        migrateBeaconProxyOwner(l2LegacySharedBridge, _aliasedGovernance);
        
        fixBridgedETHBugFix(_bridgedEthAssetId, _aliasedGovernance);
    }

    function migrateSharedBridgeLegacyOwner(
        address _l2LegacySharedBridge,
        address _aliasedGovernance
    ) internal {
        // Retrieve the proxy admin address from the proxy's storage slot.
        address proxyAdmin = address(uint160(uint256(SystemContractHelper.forcedSload(_l2LegacySharedBridge, PROXY_ADMIN_SLOT))));

        // This is an unexpected state of a network, so it is okay to revert the upgrade.
        require(proxyAdmin != address(0), "Expected TUP");

        // Generally it is expected that the admin of the proxy is an instance of the `ProxyAdmin` contract, the owner
        // of which is the decentralized governance.
        // In case this is not correct (e.g. in the past a chain might've had the aliased governance directly as the proxy admin),
        // we will deploy a new proxy admin and set its owner to be the decentralized governance.
        if (proxyAdmin.code.length == 0) {
            // It is not a `ProxyAdmin` contract, we will deploy a new proxy admin

            // TODO: do we really need to handle this case? it will complicate the upgrade script a bit
            // IMPORTANT: it means that `ProxyAdmin` should be included as the factory deps of the upgrade.
            ProxyAdmin admin = new ProxyAdmin();
            SystemContractHelper.mimicCallWithPropagatedRevert(_l2LegacySharedBridge, proxyAdmin, abi.encodeCall(ITransparentUpgradeableProxy.changeAdmin, (address(admin))));

            proxyAdmin = address(admin);
        }

        address currentOwner = ProxyAdmin(proxyAdmin).owner();
        SystemContractHelper.mimicCallWithPropagatedRevert(
            proxyAdmin,
            currentOwner,
            abi.encodeCall(Ownable2Step.transferOwnership, (_aliasedGovernance))
        );
    }

    function ensureOwnable2StepOwner(
        address _addr,
        address _aliasedGovernance
    ) internal {
        address currentOwner = Ownable2Step(_addr).owner();
        SystemContractHelper.mimicCallWithPropagatedRevert(
            _addr,
            currentOwner,
            abi.encodeCall(Ownable2Step.transferOwnership, (_aliasedGovernance))
        );
        SystemContractHelper.mimicCallWithPropagatedRevert(
            _addr,
            _aliasedGovernance,
            abi.encodeCall(Ownable2Step.acceptOwnership, ())
        );
    }

    function migrateBeaconProxyOwner(
        address _l2LegacySharedBridge,
        address _aliasedGovernance
    ) internal {
        UpgradeableBeacon l2TokenBeacon = IL2SharedBridgeLegacy(_l2LegacySharedBridge).l2TokenBeacon();
        address currentOwner = l2TokenBeacon.owner();
        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(l2TokenBeacon),
            currentOwner,
            abi.encodeCall(Ownable2Step.transferOwnership, (_aliasedGovernance))
        );
    }

    function fixBridgedETHBugFix(
        bytes32 _bridgedEthAssetId,
        address _aliasedGovernance
    ) internal {
        address bridgedETHAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_bridgedEthAssetId);
        if (bridgedETHAddress == address(0)) {
            // BridgedETH is not present, so no fix is needed
            return;
        }

        // The fixed issue is reproduced by calling `name`/`symbol` method on bridged ETH token.
        // We could try calling these methods to determine whether the issue is present, but 
        // the most straightworward way is just to reinitialize the token regardless. 
        // This will ensure that the issue will be definitely fixed and keep the logic easy to follow.

        // The `reinitializeToken` function requires us to provide the new version of the token.
        // Unfortunately it is not exposed anywhere in public API.
        // It is stored in first byte of the 0-th slot.
        uint8 version = uint8(uint256(SystemContractHelper.forcedSload(bridgedETHAddress, bytes32(0))) & 0xff);

        // Since all fields will be supported, no field needs to be ignored now.
        IBridgedStandardERC20.ERC20Getters memory getters = IBridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(bridgedETHAddress),
            _aliasedGovernance,
            abi.encodeCall(IBridgedStandardERC20.reinitializeToken, (getters, "Ether", "ETH", version + 1))
        );
    }
}
