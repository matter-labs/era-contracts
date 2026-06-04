// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";
import {Create2FactoryUtils} from "../utils/deploy/Create2FactoryUtils.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";

/// @notice One-off emergency upgrade (executed via the EmergencyUpgradeBoard) bundling two implementation
/// swaps on the stage ecosystem, both driven through PUH-owned ProxyAdmins:
///
///   1. ZKsync-OS CTM `ValidatorTimelock` proxy -> `MultisigCommitter`.
///      The v31 interopB stage-1 upgrade (block 10982340) downgraded this proxy from a MultisigCommitter
///      (`0x8419fc5e…`) to a plain ValidatorTimelock (`0x31332716…`), dropping multisig-commit behaviour.
///
///   2. L1 `ChainAssetHandler` proxy -> a new `L1ChainAssetHandler` impl that relaxes the chain-migration
///      restriction so chains can migrate from L1 to Gateways managed by a *different* CTM
///      (the `SLHasDifferentCTM()` check is now skipped for L1-origin migrations).
///
/// @dev IMPORTANT — both are PLAIN `ProxyAdmin.upgrade(proxy, newImpl)` with NO reinitializer call:
///   - The VT proxy is already at OZ `_initialized = 2` (it ran reinitializeV2/initializeV2 while it was a
///     MultisigCommitter); an impl swap does NOT wipe storage, so its multisig state (sharedValidators,
///     sharedSigningThreshold, chainConfig, cached EIP-712 domain) is intact. `reinitializeV2()` is
///     `reinitializer(2)` and would revert "already initialized" if called again.
///   - The CAH change is logic-only (no new storage, same `__gap`), so no (re)initialization is required.
///
/// Flow (two steps, mirrors the stage flow):
///   1. VPS deploys both implementations (broadcast):
///        forge script deploy-scripts/upgrade/EmergencyValidatorTimelockRestore.s.sol:EmergencyValidatorTimelockRestore \
///          --sig 'deployImpls()' --rpc-url $L1_RPC_URL --private-key <deployer> --broadcast
///   2. Emit the emergency approveHash + execute calldata for the two plain upgrades (read-only):
///        forge script deploy-scripts/upgrade/EmergencyValidatorTimelockRestore.s.sol:EmergencyValidatorTimelockRestore \
///          --sig 'runCalldata(address,address)' <newVtImpl> <newCahImpl> --rpc-url $L1_RPC_URL
contract EmergencyValidatorTimelockRestore is EmergencyStageUpgradeCalldata, Create2FactoryUtils {
    // --- ZKsync-OS CTM ValidatorTimelock ---
    /// @dev ZKsync-OS CTM ValidatorTimelock proxy (TransparentUpgradeableProxy).
    address constant ZKOS_VT_PROXY = 0x1E4299F7a19597E09bD8593AB7B68277183e9778;
    /// @dev Its ProxyAdmin — owned by the ProtocolUpgradeHandler.
    address constant ZKOS_VT_PROXY_ADMIN = 0xff3582a0310916cd62442A4CA88Bf1C757D68938;
    /// @dev The bridgehub the VT impl's immutable `BRIDGE_HUB` must point at.
    address constant ZKOS_BRIDGEHUB = 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE;

    // --- L1 ChainAssetHandler ---
    /// @dev L1 ChainAssetHandler proxy (TransparentUpgradeableProxy).
    address constant L1_CAH_PROXY = 0xCEe1A9d2FE1c587B72F115974d33296C1F9ac35d;
    /// @dev Its ProxyAdmin — owned by the ProtocolUpgradeHandler.
    address constant L1_CAH_PROXY_ADMIN = 0xCb7F8e556Ef02771eA32F54e767D6F9742ED31c2;
    /// @dev L1 bridgehub (the CAH impl's `_bridgehub` constructor arg) — same as ZKOS_BRIDGEHUB on stage.
    address constant L1_BRIDGEHUB = 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE;
    /// @dev Owner constructor arg for the CAH impl (the live proxy owner = ProtocolUpgradeHandler).
    address constant L1_CAH_OWNER = 0x8f08627524aeD610192132A425D6b9C32a1727EF;

    /// @notice Deploy both new implementations via the deterministic CREATE2 factory.
    /// @dev Run on the VPS with --broadcast. CREATE2 makes the addresses deterministic given the factory,
    ///      salt (CREATE2_FACTORY_SALT env), creation code and constructor args, so they can be cross-checked.
    ///      The CREATE2 helper broadcasts internally (Utils.deployViaCreate2 -> vm.broadcast), so do NOT
    ///      wrap these in vm.startBroadcast.
    function deployImpls() external returns (address vtImpl, address cahImpl) {
        vtImpl = deployViaCreate2AndNotify(
            type(MultisigCommitter).creationCode,
            abi.encode(ZKOS_BRIDGEHUB),
            "MultisigCommitter",
            false
        );
        cahImpl = deployViaCreate2AndNotify(
            type(L1ChainAssetHandler).creationCode,
            abi.encode(L1_CAH_OWNER, L1_BRIDGEHUB),
            "L1ChainAssetHandler",
            false
        );
        console2.log("New MultisigCommitter (VT) implementation :", vtImpl);
        console2.log("New L1ChainAssetHandler implementation     :", cahImpl);
        console2.log("Feed both into runCalldata(address,address) to emit the emergency calldata.");
    }

    /// @notice Emit the emergency-board approveHash + execute calldata for the two plain upgrades.
    /// @param _newVtImpl  The MultisigCommitter implementation deployed by `deployImpls()`.
    /// @param _newCahImpl The L1ChainAssetHandler implementation deployed by `deployImpls()`.
    function runCalldata(address _newVtImpl, address _newCahImpl) external view {
        require(_newVtImpl.code.length > 0, "VT impl has no code: deploy it on the VPS first");
        require(_newCahImpl.code.length > 0, "CAH impl has no code: deploy it on the VPS first");

        IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](2);
        // 1) Restore the ZKsync-OS ValidatorTimelock to a MultisigCommitter.
        calls[0] = IProtocolUpgradeHandler.Call({
            target: ZKOS_VT_PROXY_ADMIN,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(ZKOS_VT_PROXY)), _newVtImpl)
            )
        });
        // 2) Upgrade the L1 ChainAssetHandler to allow L1 -> other-CTM-Gateway migrations.
        calls[1] = IProtocolUpgradeHandler.Call({
            target: L1_CAH_PROXY_ADMIN,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(L1_CAH_PROXY)), _newCahImpl)
            )
        });

        _emitForCalls(calls, "VT RESTORE (ZKsync-OS) + L1 CAH MIGRATION RELAX");
    }
}
