// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {L2_ASSET_ROUTER, L2_BRIDGE_HUB, L2_NATIVE_TOKEN_VAULT, L2_CHAIN_ASSET_HANDLER} from "./Constants.sol";
import {IBridgedStandardERC20} from "./interfaces/IBridgedStandardERC20.sol";
import {LegacyBridgeNotProxy} from "./SystemContractErrors.sol";
import {IBridgehub} from "./interfaces/IBridgehub.sol";

/// @dev Storage slot with the admin of the contract used for EIP‑1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V29Upgrade, contains legacy bridge fixes, and other miscellaneous fixes.
/// @notice Performs governance‑related fixes and the Bridged‑ETH metadata patch on chains
/// that have the legacy L2 Shared Bridge.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V29Upgrade {
    /// @notice Executes the one‑time migration/patch.
    /// @dev Intended to be delegate‑called by the `ComplexUpgrader` contract.
    /// @param _aliasedGovernance The already‑aliased L1 governance address that
    /// must become the owner/admin of every affected contract.
    /// @param _bridgedEthAssetId The asset ID of the bridged ETH inside NativeTokenVault.
    function upgrade(address _aliasedGovernance, bytes32 _bridgedEthAssetId) external {
        // 1. Ensure every pre‑deployed system contract has the correct governor.
        // On public networks this is already true, but it is not the case on some
        // staging chains.
        ensureOwnable2StepOwner(address(L2_BRIDGE_HUB), _aliasedGovernance);
        ensureOwnable2StepOwner(address(L2_ASSET_ROUTER), _aliasedGovernance);
        ensureOwnable2StepOwner(address(L2_NATIVE_TOKEN_VAULT), _aliasedGovernance);

        // 2. Call setAddresses in L2 Brighehub contract to set the address of ChainAssetHandler, a new contract.
        setChainAssetHandler();

        // 3. If the legacy shared bridge does not exist on this chain, no need to proceed
        address l2LegacySharedBridge = L2_ASSET_ROUTER.L2_LEGACY_SHARED_BRIDGE();
        if (l2LegacySharedBridge == address(0)) {
            // The chain does not have a legacy L2 shared bridge; no further work required.
            return;
        }

        // 4. Migrate ownership of the legacy shared bridge and its beacon proxy.
        migrateSharedBridgeLegacyOwner(l2LegacySharedBridge, _aliasedGovernance);
        migrateBeaconProxyOwner(l2LegacySharedBridge, _aliasedGovernance);

        // 5. Patch the bridged ETH token metadata bug.
        fixBridgedETHBug(_bridgedEthAssetId, _aliasedGovernance);
    }

    /// @notice Calls setAddresses on L2 Bridgehub to set the address of newly appeared ChainAssetHandler contract.
    function setChainAssetHandler() internal {
        // Get the current L2 Brigehub owner.
        address owner = IBridgehub(L2_BRIDGE_HUB).owner();

        // Call L2 Bridgehub out of it's owner's name to setAddresses.
        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(L2_BRIDGE_HUB),
            owner,
            abi.encodeCall(IBridgehub.setChainAssetHandler, (L2_CHAIN_ASSET_HANDLER))
        );
    }

    /// @notice Makes `_aliasedGovernance` the owner of the legacy shared bridge’s
    /// TransparentUpgradeableProxy, deploying a fresh `ProxyAdmin` when
    /// the current admin is not a contract.
    /// @param _l2LegacySharedBridge Address of the legacy shared bridge proxy.
    /// @param _aliasedGovernance    New owner / admin address.
    function migrateSharedBridgeLegacyOwner(address _l2LegacySharedBridge, address _aliasedGovernance) internal {
        // Read the current proxy admin directly from storage.
        address proxyAdmin = address(
            uint160(uint256(SystemContractHelper.forcedSload(_l2LegacySharedBridge, PROXY_ADMIN_SLOT)))
        );

        if (proxyAdmin == address(0)) {
            // Unexpected state: the proxy must have an admin set.
            revert LegacyBridgeNotProxy();
        }

        // If the admin is an EOA (code length == 0), deploy a new `ProxyAdmin`
        // owned by governance and make it the proxy admin.
        if (proxyAdmin.code.length == 0) {
            // IMPORTANT: note that it requires `ProxyAdmin` to be one of the factory deps for the upgrade transaction.
            ProxyAdmin admin = new ProxyAdmin();
            SystemContractHelper.mimicCallWithPropagatedRevert(
                _l2LegacySharedBridge,
                proxyAdmin,
                abi.encodeCall(ITransparentUpgradeableProxy.changeAdmin, (address(admin)))
            );
            proxyAdmin = address(admin);
        }

        // If ownership is already correct, nothing to do.
        address currentOwner = ProxyAdmin(proxyAdmin).owner();
        if (currentOwner == _aliasedGovernance) {
            return;
        }

        // `ProxyAdmin` is not Ownable2Step – a single transfer call suffices.
        SystemContractHelper.mimicCallWithPropagatedRevert(
            proxyAdmin,
            currentOwner,
            abi.encodeCall(Ownable2Step.transferOwnership, (_aliasedGovernance))
        );
    }

    /// @notice Transfers a two‑step ownable contract to `_aliasedGovernance`
    /// and completes the `acceptOwnership` step.
    /// @param _addr               Target contract address.
    /// @param _aliasedGovernance  New owner to set and immediately accept.
    function ensureOwnable2StepOwner(address _addr, address _aliasedGovernance) internal {
        address currentOwner = Ownable2Step(_addr).owner();
        if (currentOwner == _aliasedGovernance) {
            return;
        }

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

    /// @notice Transfers ownership of the `UpgradeableBeacon` that backs
    /// bridged ERC‑20 tokens to governance.
    /// @param _l2LegacySharedBridge Address of the legacy shared bridge proxy.
    /// @param _aliasedGovernance    New owner of the beacon.
    function migrateBeaconProxyOwner(address _l2LegacySharedBridge, address _aliasedGovernance) internal {
        UpgradeableBeacon l2TokenBeacon = IL2SharedBridgeLegacy(_l2LegacySharedBridge).l2TokenBeacon();

        address currentOwner = l2TokenBeacon.owner();
        if (currentOwner == _aliasedGovernance) {
            return;
        }

        // `UpgradeableBeacon` is not Ownable2Step – a single transfer call suffices.
        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(l2TokenBeacon),
            currentOwner,
            abi.encodeCall(Ownable2Step.transferOwnership, (_aliasedGovernance))
        );
    }

    /// @notice Re‑initializes bridged ETH so that its `name`, `symbol`, and
    /// `decimals` getters work correctly.
    /// @param _bridgedEthAssetId  Asset ID of bridged ETH.
    /// @param _aliasedGovernance  Governance address allowed to call
    /// `reinitializeToken`.
    function fixBridgedETHBug(bytes32 _bridgedEthAssetId, address _aliasedGovernance) internal {
        address bridgedETHAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_bridgedEthAssetId);

        if (bridgedETHAddress == address(0)) {
            // Bridged ETH not deployed – nothing to fix.
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
        if (version == type(uint8).max) {
            // On no chain we have `version` equal to 255, but in case it does happen, we would prefer to not halt the chain
            // because due to failing upgrade, so we just silently return without fixing the issue instead of reverting.
            return;
        }

        // Since all fields will be supported, no field needs to be ignored now.
        IBridgedStandardERC20.ERC20Getters memory getters = IBridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        SystemContractHelper.mimicCallWithPropagatedRevert(
            bridgedETHAddress,
            _aliasedGovernance,
            abi.encodeCall(IBridgedStandardERC20.reinitializeToken, (getters, "Ether", "ETH", version + 1))
        );
    }
}
