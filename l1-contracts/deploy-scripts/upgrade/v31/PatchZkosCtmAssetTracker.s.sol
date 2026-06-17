// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string, gas-struct-packing, gas-length-in-loops, gas-increment-by-one

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {Utils} from "../../utils/Utils.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

/// @notice Patch (bytecode-based) for the ZKsync OS chain type manager (CTM)
///         upgrade data, motivated by https://github.com/matter-labs/era-contracts/pull/2224.
///
/// @dev PR #2224 changed the bytecode of `L2AssetTracker` (and, transitively, a
/// few other contracts). The v31 upgrade for ZKsync OS chains was already
/// prepared, so its chain-creation params / upgrade data embed stale ZKsync OS
/// bytecode descriptors. This script amends ONLY the ZKsync OS CTM data:
///   - `force_deployments_data` (chain-creation fixed force deployments), and
///   - `chain_upgrade_diamond_cut` (the upgrade transaction).
///
/// It is the bytecode-driven counterpart of the hashes-only TypeScript script
/// `scripts/patch-zkos-ctm-asset-tracker.ts`. Like the CTM upgrade scripts
/// (e.g. `CTMUpgrade_v31`), it (a) sends the changed bytecodes to the
/// `BytecodesSupplier`, and (b) **reconstructs the full CTM data from scratch**:
///   - `force_deployments_data` is rebuilt as a fresh `FixedForceDeploymentsData`
///     whose every bytecode descriptor is recomputed from the compiled artifacts
///     via the same `Utils`/`CoreOnGatewayHelper` helpers as
///     `DeployCTM._buildForceDeploymentsData`;
///   - the `chain_upgrade_diamond_cut` L2 transaction is rebuilt from the live
///     `SystemContractsProcessing.getBaseZKsyncOSForceDeployments()` +
///     `CoreOnGatewayHelper.getFullListOfFactoryDependencies()`, mirroring
///     `CTMUpgrade_v31`.
///
/// Crucially it does NOT change facets: the existing facet cuts, the diamond
/// init address and every non-bytecode scalar field are fetched from the prepared
/// upgrade output and reused verbatim. Only the bytecode-derived parts are
/// reconstructed (from the actual compiled bytecode, never the hashes file). The
/// TypeScript verifier instead byte-patches the same blobs using only
/// `AllContractsHashes.json`; diffing the two outputs proves that
/// `AllContractsHashes.json` is consistent with the artifacts and that the patch
/// is complete.
///
/// Usage (from `l1-contracts`, requires `--ffi` for the Blake2s256 helper):
///   forge script deploy-scripts/upgrade/v31/PatchZkosCtmAssetTracker.s.sol \
///       --ffi --sig "run()"
/// Optionally set `BROADCAST=true` together with an RPC / signer to actually
/// publish the new bytecodes to the `BytecodesSupplier`.
contract PatchZkosCtmAssetTracker is Script {
    using stdToml for string;

    /// @dev `ContractUpgradeType.ZKsyncOSUnsafeForceDeployment` — the v31 upgrade
    ///      delegate is force-deployed with this type (see `CTMUpgrade_v31`).
    uint8 internal constant UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT = 2;

    /// @dev The two L2 contracts whose bytecode descriptors are embedded in the
    ///      ZKsync OS CTM data and changed by PR #2224.
    string internal constant ASSET_TRACKER_FILE = "L2AssetTracker.sol";
    string internal constant ASSET_TRACKER_NAME = "L2AssetTracker";
    string internal constant V31_UPGRADE_FILE = "L2V31Upgrade.sol";
    string internal constant V31_UPGRADE_NAME = "L2V31Upgrade";

    /// @dev A ZKsync OS bytecode descriptor (blake2s, length, keccak256).
    struct BytecodeDescriptor {
        bytes32 blake;
        uint32 length;
        bytes32 keccak;
        bytes encoded; // abi.encode(blake, length, keccak)
    }

    /// @dev Working context, used to keep `run()` below the stack-too-deep limit.
    struct Ctx {
        // inputs
        bytes forceDeploymentsData;
        bytes chainUpgradeDiamondCut;
        bytes diamondCutData;
        address bytecodesSupplier;
        // old descriptors (fetched from the prepared upgrade)
        BytecodeDescriptor assetTrackerOld;
        BytecodeDescriptor v31Old;
        // new descriptors (reconstructed from the real compiled bytecode)
        BytecodeDescriptor assetTrackerNew;
        BytecodeDescriptor v31New;
        address delegateOld;
        address delegateNew;
        // outputs
        bytes newForceDeploymentsData;
        bytes newChainUpgradeDiamondCut;
    }

    function run() public {
        string memory ecosystemPath = vm.envOr(
            "ECOSYSTEM_TOML",
            string.concat(vm.projectRoot(), "/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml")
        );
        string memory outputPath = vm.envOr(
            "PATCH_OUTPUT",
            string.concat(vm.projectRoot(), "/script-out/zkos-ctm-asset-tracker-patch.forge.json")
        );

        console.log("Patching ZKsync OS CTM asset-tracker upgrade data (bytecode-based, forge)");
        console.log("  ecosystem:", ecosystemPath);
        console.log("  output:   ", outputPath);

        Ctx memory ctx;
        _loadInputs(ctx, ecosystemPath);
        _resolveDescriptors(ctx);
        _publishBytecodes(ctx);
        _regenerate(ctx);
        _doubleCheck(ctx);
        _writeOutput(ctx, outputPath);

        console.log("\nAll checks passed. Patched ZKsync OS CTM data written to:");
        console.log("  ", outputPath);
    }

    function _loadInputs(Ctx memory _ctx, string memory _ecosystemPath) internal view {
        string memory toml = vm.readFile(_ecosystemPath);
        _ctx.forceDeploymentsData = toml.readBytes("$.ctms.zksync_os.contracts_config.force_deployments_data");
        _ctx.chainUpgradeDiamondCut = toml.readBytes("$.ctms.zksync_os.chain_upgrade_diamond_cut");
        _ctx.diamondCutData = toml.readBytes("$.ctms.zksync_os.contracts_config.diamond_cut_data");
        _ctx.bytecodesSupplier = toml.readAddress("$.ctms.zksync_os.state_transition.bytecodes_supplier_addr");
    }

    function _resolveDescriptors(Ctx memory _ctx) internal {
        // existing (old) descriptors, fetched from the prepared upgrade
        _ctx.assetTrackerOld = _readAssetTrackerInfoFromFfd(_ctx.forceDeploymentsData);
        _ctx.v31Old = _findV31DelegateInfo(_ctx.chainUpgradeDiamondCut);

        // new descriptors, reconstructed from the real compiled bytecode
        _ctx.assetTrackerNew = _descriptorFromBytecode(
            BytecodeUtils.readDeployedBytecodeL1(true, ASSET_TRACKER_FILE, ASSET_TRACKER_NAME)
        );
        _ctx.v31New = _descriptorFromBytecode(
            BytecodeUtils.readDeployedBytecodeL1(true, V31_UPGRADE_FILE, V31_UPGRADE_NAME)
        );

        require(_ctx.assetTrackerNew.keccak != _ctx.assetTrackerOld.keccak, "L2AssetTracker bytecode unchanged");
        require(_ctx.v31New.keccak != _ctx.v31Old.keccak, "L2V31Upgrade bytecode unchanged");

        // The v31 delegate address is derived from its descriptor.
        _ctx.delegateOld = L2GenesisForceDeploymentsHelper.generateRandomAddress(_ctx.v31Old.encoded);
        _ctx.delegateNew = L2GenesisForceDeploymentsHelper.generateRandomAddress(_ctx.v31New.encoded);

        console.log("  L2AssetTracker length", _ctx.assetTrackerOld.length, "->", _ctx.assetTrackerNew.length);
        console.logBytes32(_ctx.assetTrackerOld.keccak);
        console.logBytes32(_ctx.assetTrackerNew.keccak);
        console.log("  L2V31Upgrade length", _ctx.v31Old.length, "->", _ctx.v31New.length);
        console.logBytes32(_ctx.v31Old.keccak);
        console.logBytes32(_ctx.v31New.keccak);
        console.log("  v31 delegate", _ctx.delegateOld, "->", _ctx.delegateNew);
    }

    function _regenerate(Ctx memory _ctx) internal {
        _ctx.newForceDeploymentsData = _reconstructForceDeploymentsData(_ctx.forceDeploymentsData);
        _ctx.newChainUpgradeDiamondCut = _reconstructUpgradeCut(_ctx);
    }

    // ------------------------------------------------------------------------
    // From-scratch reconstruction (same code paths as the CTM upgrade scripts)
    // ------------------------------------------------------------------------

    /// @notice Rebuild `FixedForceDeploymentsData` from scratch: keep the
    ///         non-bytecode config from the prepared upgrade, recompute every
    ///         bytecode descriptor from the compiled artifacts. Mirrors
    ///         `DeployCTM._buildForceDeploymentsData` for ZKsyncOS.
    function _reconstructForceDeploymentsData(bytes memory _oldFfd) internal returns (bytes memory) {
        FixedForceDeploymentsData memory data = abi.decode(_oldFfd, (FixedForceDeploymentsData));
        data.bridgehubBytecodeInfo = _coreBytecodeInfo(CoreContract.L2Bridgehub);
        data.l2AssetRouterBytecodeInfo = _coreBytecodeInfo(CoreContract.L2AssetRouter);
        data.l2NtvBytecodeInfo = _coreBytecodeInfo(CoreContract.L2NativeTokenVault);
        data.messageRootBytecodeInfo = _coreBytecodeInfo(CoreContract.L2MessageRoot);
        data.beaconDeployerInfo = _coreBytecodeInfo(CoreContract.UpgradeableBeaconDeployer);
        data.baseTokenHolderBytecodeInfo = _coreBytecodeInfo(CoreContract.BaseTokenHolder);
        data.chainAssetHandlerBytecodeInfo = _coreBytecodeInfo(CoreContract.L2ChainAssetHandler);
        data.interopCenterBytecodeInfo = _coreBytecodeInfo(CoreContract.InteropCenter);
        data.interopHandlerBytecodeInfo = _coreBytecodeInfo(CoreContract.InteropHandler);
        data.assetTrackerBytecodeInfo = _coreBytecodeInfo(CoreContract.L2AssetTracker);
        return abi.encode(data);
    }

    /// @dev ZKsyncOS proxy-upgrade bytecode info for a fixed-address core contract,
    ///      resolved + hashed exactly like `DeployCTM._getBytecodeInfo`.
    function _coreBytecodeInfo(CoreContract _id) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, _id);
        return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
    }

    /// @notice Rebuild the ZKsyncOS upgrade `DiamondCutData` from scratch. Facet
    ///         cuts / init address / scalar fields are taken from the prepared
    ///         upgrade (facets are NOT changed); the L2 upgrade transaction's
    ///         force deployments, factory deps and delegate are reconstructed.
    function _reconstructUpgradeCut(Ctx memory _ctx) internal returns (bytes memory) {
        Diamond.DiamondCutData memory cut = abi.decode(_ctx.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        ProposedUpgrade memory proposed = abi.decode(_sliceFromSelector(cut.initCalldata), (ProposedUpgrade));

        // `ctmDeploymentTracker` is an ecosystem address, taken from the existing
        // v31 L2 upgrade calldata (not derived from bytecode).
        (, , bytes memory oldInner) = abi.decode(
            _sliceFromSelector(proposed.l2ProtocolUpgradeTx.data),
            (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes)
        );
        (, address ctmDeploymentTracker, , ) = abi.decode(_sliceFromSelector(oldInner), (bool, address, bytes, bytes));

        // Reconstruct the force-deployment list exactly as CTMUpgrade_v31 does:
        // base ZKsyncOS system-proxy upgrades + the single v31 unsafe delegate.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .mergeUniversalForceDeployments(
                SystemContractsProcessing.getBaseZKsyncOSForceDeployments(),
                _v31AdditionalForceDeployments()
            );

        bytes memory v31Info = Utils.getZKOSBytecodeInfoForContract(V31_UPGRADE_FILE, V31_UPGRADE_NAME);
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(v31Info);

        // Inner v31 calldata embeds the freshly reconstructed force deployments data.
        bytes memory inner = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (true, ctmDeploymentTracker, _ctx.newForceDeploymentsData, "")
        );
        proposed.l2ProtocolUpgradeTx.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (deployments, delegateTo, inner)
        );

        // Reconstruct factory deps from the full dependency list (keccak per dep,
        // matching BytecodePublisher for ZKsyncOS).
        CoreContract[] memory additional = new CoreContract[](1);
        additional[0] = CoreContract.L2V31Upgrade;
        bytes[] memory deps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, additional);
        uint256[] memory factoryDeps = new uint256[](deps.length);
        for (uint256 i; i < deps.length; i++) {
            factoryDeps[i] = uint256(keccak256(deps[i]));
        }
        proposed.l2ProtocolUpgradeTx.factoryDeps = factoryDeps;

        cut.initCalldata = abi.encodeCall(DefaultUpgrade.upgrade, (proposed));
        return abi.encode(cut);
    }

    /// @dev Mirrors `CTMUpgrade_v31.getV31AdditionalZKsyncOSUniversalForceDeployments`.
    function _v31AdditionalForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract(V31_UPGRADE_FILE, V31_UPGRADE_NAME);
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: bytecodeInfo,
            newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
        });
    }

    function _doubleCheck(Ctx memory _ctx) internal pure {
        // The reconstructed data must carry the NEW descriptors...
        require(
            _indexOf(_ctx.newForceDeploymentsData, _ctx.assetTrackerNew.encoded, 0) != type(uint256).max,
            "reconstructed force deployments missing new asset tracker"
        );
        require(
            _indexOf(_ctx.newChainUpgradeDiamondCut, _ctx.assetTrackerNew.encoded, 0) != type(uint256).max &&
                _indexOf(_ctx.newChainUpgradeDiamondCut, _ctx.v31New.encoded, 0) != type(uint256).max,
            "reconstructed upgrade cut missing new descriptors"
        );

        // ...and none of the stale descriptors / keccaks / delegate address.
        _assertAbsent(_ctx.newForceDeploymentsData, _ctx.assetTrackerOld);
        _assertAbsent(_ctx.newChainUpgradeDiamondCut, _ctx.assetTrackerOld);
        _assertAbsent(_ctx.newChainUpgradeDiamondCut, _ctx.v31Old);
        require(
            _indexOf(_ctx.newChainUpgradeDiamondCut, abi.encodePacked(_ctx.delegateOld), 0) == type(uint256).max,
            "stale delegate"
        );

        // The chain-creation diamond cut must NOT reference any of these
        // descriptors and must be left untouched.
        require(
            _indexOf(_ctx.diamondCutData, bytes.concat(_ctx.assetTrackerNew.keccak), 0) == type(uint256).max &&
                _indexOf(_ctx.diamondCutData, bytes.concat(_ctx.v31New.keccak), 0) == type(uint256).max,
            "diamond_cut_data unexpectedly references patched descriptors"
        );
    }

    // ------------------------------------------------------------------------
    // Descriptor construction
    // ------------------------------------------------------------------------

    function _descriptorFromBytecode(bytes memory _bytecode) internal returns (BytecodeDescriptor memory d) {
        d.blake = Utils.blakeHashBytecode(_bytecode);
        d.length = uint32(_bytecode.length);
        d.keccak = keccak256(_bytecode);
        d.encoded = ZKSyncOSBytecodeInfo.encodeZKSyncOSBytecodeInfo(d.blake, d.length, d.keccak);
    }

    function _descriptorFromEncoded(bytes memory _encoded) internal pure returns (BytecodeDescriptor memory d) {
        (d.blake, d.length, d.keccak) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(_encoded);
        d.encoded = _encoded;
    }

    /// @notice Decode the asset-tracker implementation descriptor from a
    ///         `FixedForceDeploymentsData` blob (`assetTrackerBytecodeInfo` is
    ///         abi.encode(implInfo, proxyInfo); we take the implementation part).
    function _readAssetTrackerInfoFromFfd(bytes memory _ffd) internal pure returns (BytecodeDescriptor memory) {
        FixedForceDeploymentsData memory data = abi.decode(_ffd, (FixedForceDeploymentsData));
        (bytes memory implInfo, ) = abi.decode(data.assetTrackerBytecodeInfo, (bytes, bytes));
        return _descriptorFromEncoded(implInfo);
    }

    /// @notice Decode the single `ZKsyncOSUnsafeForceDeployment` (v31 delegate)
    ///         descriptor from a `chain_upgrade_diamond_cut` blob.
    function _findV31DelegateInfo(
        bytes memory _chainUpgradeDiamondCut
    ) internal pure returns (BytecodeDescriptor memory) {
        Diamond.DiamondCutData memory cut = abi.decode(_chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        // initCalldata = DefaultUpgrade.upgrade(ProposedUpgrade); strip selector.
        ProposedUpgrade memory proposed = abi.decode(_sliceFromSelector(cut.initCalldata), (ProposedUpgrade));
        // tx.data = forceDeployAndUpgradeUniversal(deployments, delegateTo, calldata); strip selector.
        (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments, , ) = abi.decode(
            _sliceFromSelector(proposed.l2ProtocolUpgradeTx.data),
            (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes)
        );

        bool found;
        BytecodeDescriptor memory result;
        for (uint256 i; i < deployments.length; i++) {
            if (uint8(deployments[i].upgradeType) == UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT) {
                require(!found, "multiple ZKsyncOSUnsafeForceDeployment entries");
                found = true;
                result = _descriptorFromEncoded(deployments[i].deployedBytecodeInfo);
            }
        }
        require(found, "v31 delegate (ZKsyncOSUnsafeForceDeployment) not found");
        return result;
    }

    // ------------------------------------------------------------------------
    // Bytecode supplier
    // ------------------------------------------------------------------------

    function _publishBytecodes(Ctx memory _ctx) internal {
        bytes[] memory bytecodes = new bytes[](2);
        bytecodes[0] = BytecodeUtils.readDeployedBytecodeL1(true, ASSET_TRACKER_FILE, ASSET_TRACKER_NAME);
        bytecodes[1] = BytecodeUtils.readDeployedBytecodeL1(true, V31_UPGRADE_FILE, V31_UPGRADE_NAME);

        bytes memory publishCalldata = abi.encodeCall(BytecodesSupplier.publishEVMBytecodes, (bytecodes));
        console.log("  bytecodesSupplier:", _ctx.bytecodesSupplier);
        console.log("  publishEVMBytecodes calldata length:", publishCalldata.length);

        if (vm.envOr("BROADCAST", false)) {
            vm.broadcast(Utils.getBroadcasterAddress());
            BytecodesSupplier(_ctx.bytecodesSupplier).publishEVMBytecodes(bytecodes);
            console.log("  published 2 EVM bytecodes to the supplier");
        } else {
            console.log("  dry-run: not broadcasting (set BROADCAST=true to publish)");
        }
    }

    // ------------------------------------------------------------------------
    // Verification helpers
    // ------------------------------------------------------------------------

    /// @dev Returns the first index of `_needle` in `_haystack` at or after
    ///      `_start`, or `type(uint256).max` if not found.
    function _indexOf(bytes memory _haystack, bytes memory _needle, uint256 _start) internal pure returns (uint256) {
        if (_needle.length == 0 || _haystack.length < _needle.length) {
            return type(uint256).max;
        }
        uint256 limit = _haystack.length - _needle.length;
        for (uint256 i = _start; i <= limit; i++) {
            bool matched = true;
            for (uint256 j; j < _needle.length; j++) {
                if (_haystack[i + j] != _needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _assertAbsent(bytes memory _data, BytecodeDescriptor memory _old) internal pure {
        require(_indexOf(_data, _old.encoded, 0) == type(uint256).max, "stale descriptor present");
        require(_indexOf(_data, bytes.concat(_old.keccak), 0) == type(uint256).max, "stale keccak present");
        require(_indexOf(_data, bytes.concat(_old.blake), 0) == type(uint256).max, "stale blake present");
    }

    /// @dev Returns `_data` without its leading 4-byte function selector.
    function _sliceFromSelector(bytes memory _data) internal pure returns (bytes memory out) {
        require(_data.length >= 4, "calldata too short");
        out = new bytes(_data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = _data[i + 4];
        }
    }

    // ------------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------------

    function _writeOutput(Ctx memory _ctx, string memory _outputPath) internal {
        string memory obj = "patch";
        vm.serializeString(obj, "ctm", "zksync_os");
        vm.serializeAddress(obj, "bytecodesSupplier", _ctx.bytecodesSupplier);
        vm.serializeBytes32(obj, "assetTrackerOldKeccak", _ctx.assetTrackerOld.keccak);
        vm.serializeBytes32(obj, "assetTrackerNewKeccak", _ctx.assetTrackerNew.keccak);
        vm.serializeBytes32(obj, "v31OldKeccak", _ctx.v31Old.keccak);
        vm.serializeBytes32(obj, "v31NewKeccak", _ctx.v31New.keccak);
        vm.serializeAddress(obj, "v31DelegateOld", _ctx.delegateOld);
        vm.serializeAddress(obj, "v31DelegateNew", _ctx.delegateNew);
        vm.serializeBytes(obj, "diamondCutDataUnchanged", _ctx.diamondCutData);
        vm.serializeBytes(obj, "forceDeploymentsData", _ctx.newForceDeploymentsData);
        string memory finalJson = vm.serializeBytes(obj, "chainUpgradeDiamondCut", _ctx.newChainUpgradeDiamondCut);
        vm.writeJson(finalJson, _outputPath);
    }
}
