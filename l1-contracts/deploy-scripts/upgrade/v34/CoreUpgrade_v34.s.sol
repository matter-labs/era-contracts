// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {Call} from "contracts/governance/Common.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {CoreRegistryManifest, PinnedContract, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    L1EcosystemContract,
    L1_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice Core (ecosystem) side of the v34 upgrade: deploys the new shared-singleton
///         implementation set, pins it in a write-once `CoreRegistry` (the enum-indexed
///         inventory — one slot per `L1EcosystemContract` member, inert slots explicit), and
///         hands the ecosystem `ProxyAdmin` to the bound `EcosystemUpgradeExecutor`. Stage 1
///         carries TWO ecosystem calls — the ProxyAdmin handover and `applyL1Upgrade(registry)`
///         — instead of one raw `ProxyAdmin.upgrade` per proxy; the rows are source-checked
///         edges, so a replay can never downgrade a proxy a later upgrade has moved on.
contract CoreUpgrade_v34 is DefaultCoreUpgrade {
    /// @notice The bound executor the ecosystem `ProxyAdmin` lands under. Deployed by this
    ///         prepare run.
    EcosystemUpgradeExecutor public ecosystemUpgradeExecutor;

    /// @notice The write-once inventory of this upgrade's implementation swaps.
    CoreRegistry public coreRegistry;

    /// @notice Deploy the v34 ecosystem-wide implementation set (implementations only).
    function deployNewEcosystemContractsL1() public virtual override {
        // Defensive: on ecosystems whose discovery misses the ChainRegistrationSender proxy
        // (see the v32 script for the introspection edge case), read it from the bridgehub so
        // the force-deployments data carries the correct aliased sender.
        if (coreAddresses.bridgehub.proxies.chainRegistrationSender == address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = IBridgehubBase(
                coreAddresses.bridgehub.proxies.bridgehub
            ).chainRegistrationSender();
        }

        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub");
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier");
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter");
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault");
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract("CTMDeploymentTracker");
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler");
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender"
        );
    }

    function prepareEcosystemUpgrade() public virtual override {
        super.prepareEcosystemUpgrade();
        // AFTER the implementation deploys: the registry pins them.
        deployCoreRegistryBootstrap();
    }

    /// @notice The break-glass governor of the deployed `EcosystemUpgradeExecutor`.
    /// @dev Defaults to the upgrade owner so local/test runs work unconfigured. A PRODUCTION run
    ///      MUST override this with the real EmergencyUpgradeBoard.
    function getEmergencyUpgradeBoard() public virtual returns (address) {
        return getOwnerAddress();
    }

    /// @notice Deploys the write-once inventory of this upgrade's swaps and the bound executor
    ///         that applies it.
    /// @dev Both ride the CREATE2 factory: the Safe bundle replays factory transactions only, so
    ///      a plain CREATE would leave the stage-1 calls pointing at codeless addresses.
    function deployCoreRegistryBootstrap() public virtual {
        coreRegistry = CoreRegistry(
            deployViaCreate2AndNotify(
                type(CoreRegistry).creationCode,
                abi.encode(CoreRegistryManifest({proxyUpgrades: _coreProxyUpgradeRows()})),
                "CoreRegistry"
            )
        );

        ecosystemUpgradeExecutor = EcosystemUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(EcosystemUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        getEmergencyUpgradeBoard(),
                        ProxyAdmin(coreAddresses.shared.transparentProxyAdmin),
                        // The audited-object anchor for every registry this executor accepts.
                        keccak256(vm.getDeployedCode("CoreRegistry.sol:CoreRegistry"))
                    ),
                    "EcosystemUpgradeExecutor"
                )
            )
        );
    }

    /// @notice The enum-indexed ecosystem inventory: one slot per `L1EcosystemContract` member,
    ///         a source-checked row (live impl read from the EIP-1967 slot) for every proxy this
    ///         upgrade swaps, every other slot an explicit inert zero.
    function _coreProxyUpgradeRows() internal view returns (ProxyUpgradeRow[] memory rows) {
        rows = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        rows[uint256(L1EcosystemContract.L1Bridgehub)] = _row(
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridgehub.implementations.bridgehub
        );
        rows[uint256(L1EcosystemContract.L1Nullifier)] = _row(
            coreAddresses.bridges.proxies.l1Nullifier,
            coreAddresses.bridges.implementations.l1Nullifier
        );
        rows[uint256(L1EcosystemContract.L1AssetRouter)] = _row(
            coreAddresses.bridges.proxies.l1AssetRouter,
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        rows[uint256(L1EcosystemContract.L1NativeTokenVault)] = _row(
            coreAddresses.bridges.proxies.l1NativeTokenVault,
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );
        // L1MessageRoot is a plain upgrade like the rest: v31's reinitializer was removed in
        // this release, and every ecosystem it can upgrade had already consumed that version.
        rows[uint256(L1EcosystemContract.L1MessageRoot)] = _row(
            coreAddresses.bridgehub.proxies.messageRoot,
            coreAddresses.bridgehub.implementations.messageRoot
        );
        rows[uint256(L1EcosystemContract.CTMDeploymentTracker)] = _row(
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        rows[uint256(L1EcosystemContract.L1ChainAssetHandler)] = _row(
            coreAddresses.bridgehub.proxies.chainAssetHandler,
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
    }

    function _row(address _proxy, address _implNew) internal view returns (ProxyUpgradeRow memory) {
        require(_implNew != address(0), "new implementation not deployed");
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: Utils.getImplementation(_proxy),
                implNew: PinnedContract({addr: _implNew, codehash: _implNew.codehash}),
                callInitializeUpgrade: false
            });
    }

    /// @notice The proxy swaps ride the registry: stage 1 hands the ecosystem `ProxyAdmin` to
    ///         the bound executor and applies the pinned inventory in ONE call, replacing one
    ///         raw `ProxyAdmin.upgrade` per proxy.
    function prepareUpgradeProxiesCalls() public virtual override returns (Call[] memory calls) {
        require(address(coreRegistry) != address(0), "core registry not deployed");
        calls = new Call[](2);
        calls[0] = Call({
            target: coreAddresses.shared.transparentProxyAdmin,
            data: abi.encodeCall(Ownable.transferOwnership, (address(ecosystemUpgradeExecutor))),
            value: 0
        });
        calls[1] = Call({
            target: address(ecosystemUpgradeExecutor),
            data: abi.encodeCall(EcosystemUpgradeExecutor.applyL1Upgrade, (ICoreRegistry(address(coreRegistry)))),
            value: 0
        });
    }

    /// @notice The stage-2 ecosystem gate is the executor's own post-state check: every registry
    ///         row's proxy points at its pinned implementation, read live through the bound
    ///         `ProxyAdmin` — one reverting view call instead of composed per-proxy checks.
    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        require(address(coreRegistry) != address(0), "core registry not deployed");
        calls = new Call[](1);
        calls[0] = Call({
            target: address(ecosystemUpgradeExecutor),
            data: abi.encodeCall(
                EcosystemUpgradeExecutor.validateUpgradeApplied,
                (ICoreRegistry(address(coreRegistry)))
            ),
            value: 0
        });
    }

    /// @notice Override to properly set deployerAddress in upgrade context.
    /// @dev In Forge scripts with vm.broadcast(), msg.sender is the script address, but the
    ///      actual deployer is the broadcast key — same fix as every upgrade script needs.
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();
        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:", config.deployerAddress);
    }
}
