// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";
import {Create2FactoryUtils} from "../utils/deploy/Create2FactoryUtils.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";

/// @notice One-off emergency upgrade (executed via the EmergencyUpgradeBoard) that restores the ZKsync-OS
/// CTM `ValidatorTimelock` proxy back to a `MultisigCommitter` implementation, driven through the
/// PUH-owned ProxyAdmin. The v31 interopB stage-1 upgrade (block 10982340) downgraded this proxy from a
/// MultisigCommitter (`0x8419fc5e…`) to a plain ValidatorTimelock (`0x31332716…`), dropping multisig-commit
/// behaviour.
///
/// @dev IMPORTANT — PLAIN `ProxyAdmin.upgrade(proxy, newImpl)` with NO reinitializer call:
/// The proxy is already at OZ `_initialized = 2` (it ran reinitializeV2/initializeV2 while it was a
/// MultisigCommitter); an implementation swap does NOT wipe storage, so its multisig state
/// (sharedValidators, sharedSigningThreshold, chainConfig, cached EIP-712 domain) is intact.
/// `MultisigCommitter.reinitializeV2()` is `reinitializer(2)` and would revert "already initialized" if
/// called again.
///
/// @dev The L1 ChainAssetHandler migration relaxation was intentionally dropped from this proposal: the
/// same-CTM restriction is also enforced in the Migrator, so a CAH-only impl swap does not enable
/// L1 -> other-CTM-Gateway migration. That needs a separate change.
///
/// Flow (two steps):
///   1. VPS deploys the implementation (broadcast) — already deployed at 0x3Ccb407b… on Sepolia:
///        forge script deploy-scripts/upgrade/EmergencyValidatorTimelockRestore.s.sol:EmergencyValidatorTimelockRestore \
///          --sig 'deployImpl()' --rpc-url $L1_RPC_URL --private-key <deployer> --broadcast
///   2. Emit the emergency approveHash + execute calldata for the single plain upgrade (read-only):
///        forge script deploy-scripts/upgrade/EmergencyValidatorTimelockRestore.s.sol:EmergencyValidatorTimelockRestore \
///          --sig 'runCalldata(address)' <newVtImpl> --rpc-url $L1_RPC_URL
contract EmergencyValidatorTimelockRestore is EmergencyStageUpgradeCalldata, Create2FactoryUtils {
    /// @dev ZKsync-OS CTM ValidatorTimelock proxy (TransparentUpgradeableProxy).
    address constant ZKOS_VT_PROXY = 0x1E4299F7a19597E09bD8593AB7B68277183e9778;
    /// @dev Its ProxyAdmin — owned by the ProtocolUpgradeHandler.
    address constant ZKOS_VT_PROXY_ADMIN = 0xff3582a0310916cd62442A4CA88Bf1C757D68938;
    /// @dev The bridgehub the VT impl's immutable `BRIDGE_HUB` must point at.
    address constant ZKOS_BRIDGEHUB = 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE;

    /// @notice Deploy the new MultisigCommitter implementation via the deterministic CREATE2 factory.
    /// @dev Run on the VPS with --broadcast. The CREATE2 helper broadcasts internally
    ///      (Utils.deployViaCreate2 -> vm.broadcast), so do NOT wrap this in vm.startBroadcast.
    function deployImpl() external returns (address vtImpl) {
        vtImpl = deployViaCreate2AndNotify(
            type(MultisigCommitter).creationCode,
            abi.encode(ZKOS_BRIDGEHUB),
            "MultisigCommitter",
            false
        );
        console2.log("New MultisigCommitter (VT) implementation:", vtImpl);
        console2.log("Feed this into runCalldata(address) to emit the emergency calldata.");
    }

    /// @notice Emit the emergency-board approveHash + execute calldata for the single plain upgrade.
    /// @param _newVtImpl The MultisigCommitter implementation deployed by `deployImpl()`.
    function runCalldata(address _newVtImpl) external view {
        require(_newVtImpl.code.length > 0, "VT impl has no code: deploy it on the VPS first");

        IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](1);
        // Restore the ZKsync-OS ValidatorTimelock to a MultisigCommitter.
        calls[0] = IProtocolUpgradeHandler.Call({
            target: ZKOS_VT_PROXY_ADMIN,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(ZKOS_VT_PROXY)), _newVtImpl)
            )
        });

        _emitForCalls(calls, "VT RESTORE (ZKsync-OS -> MultisigCommitter)");
    }
}
