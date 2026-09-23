// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {Utils} from "../../utils/Utils.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {EraForceDeploymentsLib} from "../default-upgrade/EraForceDeploymentsLib.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

/// @notice v33: a compiler-only upgrade of an Era CTM that is already on the v31 contract line.
/// @dev What it ships: the EraVM bytecode rebuilt with zksolc 1.5.17 and the DSE-safe bootloader
/// (root-frame hooks preserved) — the bootloader, default account and EVM emulator hashes, plus the
/// 31 system contracts, force-deployed at their fixed addresses by one L2 upgrade transaction.
///
/// What it deliberately does NOT touch, so that the upgraded CTM keeps running exactly the L1 code
/// it runs today:
///  - no L1 contract is deployed: the upgrade reuses the CTM's existing `DefaultUpgrade` (compiled
///    against the live diamond's storage layout), the existing `BytecodesSupplier`, the existing
///    verifier and the existing facets (`facetCuts` is empty);
///  - the fixed-address L2 core contracts (bridgehub, asset router, NTV, message root, …) keep their
///    current code. They carry live storage and, for the NTV and the chain asset handler, constructor
///    state that a plain force deployment would reset; the compiler fix is in the system layer.
///
/// New chains: `setChainCreationParams` re-issues the CTM's current creation parameters (same
/// genesis upgrade, facets and diamond init) with the genesis batch values and the three
/// base-system hashes replaced, so a chain created at v33 starts from the v33 genesis. The
/// force-deployment data is rebuilt: the blob stage stores predates the removal of
/// `gatewayChainId` from `FixedForceDeploymentsData` (#2239), so the v33 genesis's
/// `L2GenesisUpgrade` could not decode it, and it names the old compile's L2 built-ins, which a v33
/// genesis does not know. The rebuilt blob uses this branch's layout and bytecode, and carries
/// every non-bytecode value over from the stored blob after checking it against the bridgehub.
/// The input carries the current parameters as the data of the CTM's last `NewChainCreationParams`
/// event; the script checks them against the CTM's stored hashes before using them.
///
/// Governance calls, all owned by the ecosystem governance (the CTM's and ChainAssetHandler's owner):
///  - stage 0: `ChainAssetHandler.pauseMigration()` — the CTM refuses `setNewVersionUpgrade` while
///    Gateway migrations are live (`MigrationsNotPaused`);
///  - stage 1: `setNewVersionUpgrade`, then `setChainCreationParams`;
///  - stage 2: `ChainAssetHandler.unpauseMigration()`.
/// Stages can run in one emergency upgrade, as stage's v0.32.x upgrades did.
///
/// Entry point: `prepare(inputPath, outputPath)`. Publishing the factory dependencies is the only
/// broadcast (permissionless, from the broadcaster); everything else is emitted as governance calls
/// and per-chain admin calls in the output TOML.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v33 is Script, DefaultCTMUpgrade {
    using stdToml for string;

    /// @notice Parsed input, see `upgrade-envs/v0.33.0-compiler/<env>.toml`.
    // solhint-disable-next-line gas-struct-packing
    struct V33Input {
        address ctm;
        address bytecodesSupplier;
        address defaultUpgrade;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        bytes currentChainCreationParamsEvent;
        uint256[] chainIds;
    }

    V33Input internal v33Input;
    /// @dev abi-encoded ChainCreationParams / Diamond.DiamondCutData (structs with nested dynamic
    ///      arrays cannot be copied to storage by the legacy pipeline).
    bytes internal v33NewChainCreationParams;
    bytes internal v33UpgradeCut;
    address internal v33Verifier;

    function prepare(string memory _inputPath, string memory _outputPath) public {
        string memory root = vm.projectRoot();
        _loadInput(string.concat(root, _inputPath));
        _checkLiveState();
        _initializeV33Config();

        // Era invariant checked inside: factory deps [0..2] == genesis bootloader / AA / EVM emulator.
        publishBytecodes();
        console.log("v33: factory dependencies published");

        v33UpgradeCut = abi.encode(_buildUpgradeCut());
        v33NewChainCreationParams = abi.encode(_buildNewChainCreationParams());

        _saveV33Output(string.concat(root, _outputPath));
    }

    // ======================== Input and live-state checks ========================

    function _loadInput(string memory _path) internal {
        string memory toml = vm.readFile(_path);
        v33Input.ctm = toml.readAddress("$.ctm");
        v33Input.bytecodesSupplier = toml.readAddress("$.bytecodes_supplier");
        v33Input.defaultUpgrade = toml.readAddress("$.default_upgrade");
        v33Input.oldProtocolVersion = toml.readUint("$.old_protocol_version");
        v33Input.newProtocolVersion = toml.readUint("$.new_protocol_version");
        v33Input.currentChainCreationParamsEvent = toml.readBytes("$.current_chain_creation_params_event_data");
        v33Input.chainIds = toml.readUintArray("$.chain_ids");
    }

    /// @dev Fail before publishing anything if the input does not describe the live CTM.
    function _checkLiveState() internal {
        IChainTypeManager ctm = IChainTypeManager(v33Input.ctm);
        require(ctm.protocolVersion() == v33Input.oldProtocolVersion, "v33: CTM not on old version");
        require(
            UpgradeHelperLib.getProtocolUpgradeNonce(v33Input.newProtocolVersion) ==
                UpgradeHelperLib.getProtocolUpgradeNonce(v33Input.oldProtocolVersion) + 1,
            "v33: new version not next minor"
        );
        require(!UpgradeHelperLib.isPatchUpgrade(v33Input.newProtocolVersion), "v33: must be a minor upgrade");
        require(v33Input.defaultUpgrade.code.length > 0, "v33: default_upgrade no code");
        require(v33Input.bytecodesSupplier.code.length > 0, "v33: bytecodes_supplier no code");

        v33Verifier = ctm.protocolVersionVerifier(v33Input.oldProtocolVersion);
        require(v33Verifier != address(0), "v33: no verifier for old version");

        (
            address genesisUpgrade,
            ,
            ,
            ,
            Diamond.DiamondCutData memory initialCut,
            bytes32 initialCutHash,
            bytes memory forceDeploymentsData,
            bytes32 forceDeploymentHash
        ) = _decodeChainCreationParamsEvent();
        require(genesisUpgrade == ctm.l1GenesisUpgrade(), "v33: genesis upgrade mismatch");
        require(initialCutHash == ctm.initialCutHash(), "v33: stale creation cut");
        require(keccak256(abi.encode(initialCut)) == initialCutHash, "v33: creation cut hash mismatch");
        require(
            forceDeploymentHash == IChainTypeManagerV31Views(v33Input.ctm).initialForceDeploymentHash(),
            "v33: stale force deployments"
        );
        // ChainTypeManagerBase hashes the ABI-encoded bytes, not the raw bytes.
        require(keccak256(abi.encode(forceDeploymentsData)) == forceDeploymentHash, "v33: force deployments hash");

        uint256 chainCount = v33Input.chainIds.length;
        for (uint256 i = 0; i < chainCount; ++i) {
            address chain = ctm.getZKChain(v33Input.chainIds[i]);
            require(chain != address(0), "v33: chain not on CTM");
            require(
                IGetters(chain).getProtocolVersion() == v33Input.oldProtocolVersion,
                "v33: chain not on old version"
            );
        }
    }

    function _initializeV33Config() internal {
        config.l1ChainId = block.chainid;
        config.isZKsyncOS = false;
        newConfig.ctm = v33Input.ctm;
        newConfig.oldProtocolVersion = v33Input.oldProtocolVersion;
        ctmAddresses.stateTransition.proxies.chainTypeManager = v33Input.ctm;
        ctmAddresses.stateTransition.proxies.bytecodesSupplier = v33Input.bytecodesSupplier;
        ctmAddresses.stateTransition.defaultUpgrade = v33Input.defaultUpgrade;
        ctmAddresses.stateTransition.verifiers.verifier = v33Verifier;

        // Genesis batch values and base-system hashes come from this branch's Era genesis; the
        // version from the input (the genesis file keeps the branch's own release version).
        config.contracts.chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath(false));
        config.contracts.chainCreationParams.latestProtocolVersion = v33Input.newProtocolVersion;
        upgradeConfig.initialized = true;
    }

    // ======================== Upgrade data ========================

    /// @dev Empty facet cut: the diamond keeps its facets; `DefaultUpgrade` only swaps the base
    ///      system hashes, bumps the version and schedules the L2 upgrade transaction.
    function _buildUpgradeCut() internal returns (Diamond.DiamondCutData memory upgradeCut) {
        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade({
            _stateTransition: ctmAddresses.stateTransition,
            _chainCreationParams: config.contracts.chainCreationParams,
            _l1ChainId: config.l1ChainId,
            _ownerAddress: address(0),
            _factoryDepsResult: factoryDepsResult,
            _protocolUpgradeNonce: UpgradeHelperLib.getProtocolUpgradeNonce(v33Input.newProtocolVersion)
        });
        upgradeCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: v33Input.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });
    }

    /// @dev The CTM's current creation parameters with only the genesis batch values and the
    ///      diamond init's base-system hashes replaced.
    function _buildNewChainCreationParams() internal returns (ChainCreationParams memory params) {
        (
            address genesisUpgrade,
            ,
            ,
            ,
            Diamond.DiamondCutData memory initialCut,
            ,
            bytes memory forceDeploymentsData,

        ) = _decodeChainCreationParamsEvent();

        // The diamond init's calldata is exactly InitializeDataNewChain; re-encode it with the
        // v33 hashes (decoding first also proves the input has that shape).
        abi.decode(initialCut.initCalldata, (InitializeDataNewChain));
        initialCut.initCalldata = abi.encode(
            InitializeDataNewChain({
                l2BootloaderBytecodeHash: config.contracts.chainCreationParams.bootloaderHash,
                l2DefaultAccountBytecodeHash: config.contracts.chainCreationParams.defaultAAHash,
                l2EvmEmulatorBytecodeHash: config.contracts.chainCreationParams.evmEmulatorHash
            })
        );

        params = ChainCreationParams({
            genesisUpgrade: genesisUpgrade,
            genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
            diamondCut: initialCut,
            forceDeploymentsData: _rebuildForceDeploymentsData(forceDeploymentsData)
        });
    }

    /// @dev Rebuild the new-chain force-deployment data in this branch's layout and with this
    ///      branch's L2 bytecode, carrying the non-bytecode values over from the CTM's stored blob.
    ///      Each carried value is checked against the live bridgehub / CTM first.
    function _rebuildForceDeploymentsData(bytes memory _stored) internal returns (bytes memory) {
        LegacyFixedForceDeploymentsData memory stored = abi.decode(_stored, (LegacyFixedForceDeploymentsData));
        IChainTypeManager ctm = IChainTypeManager(v33Input.ctm);
        IBridgehubBase bridgehub = IBridgehubBase(ctm.BRIDGE_HUB());

        address governance = AddressAliasHelper.undoL1ToL2Alias(stored.aliasedL1Governance);
        address chainRegistrationSender = AddressAliasHelper.undoL1ToL2Alias(stored.aliasedChainRegistrationSender);
        require(stored.l1ChainId == block.chainid, "v33: stored l1ChainId mismatch");
        require(stored.l1AssetRouter == address(bridgehub.assetRouter()), "v33: stored asset router stale");
        require(governance == IOwnable(address(ctm)).owner(), "v33: stored governance stale");
        require(chainRegistrationSender == bridgehub.chainRegistrationSender(), "v33: stored CRS stale");
        // The builder hard-codes these to zero; refuse to silently drop a non-zero value.
        require(
            stored.l2SharedBridgeLegacyImpl == address(0) && stored.l2BridgedStandardERC20Impl == address(0),
            "v33: stored legacy impls set"
        );

        config.eraChainId = stored.eraChainId;
        config.contracts.maxNumberOfChains = stored.maxNumberOfZKChains;
        config.zkTokenAssetId = stored.zkTokenAssetId;
        coreAddresses.bridges.proxies.l1AssetRouter = stored.l1AssetRouter;
        coreAddresses.bridgehub.proxies.chainRegistrationSender = chainRegistrationSender;

        FixedForceDeploymentsData memory rebuilt = _buildForceDeploymentsData(
            governance,
            stored.dangerousTestOnlyForcedBeacon
        );
        require(rebuilt.aliasedL1Governance == stored.aliasedL1Governance, "v33: governance alias differs");
        require(
            rebuilt.aliasedChainRegistrationSender == stored.aliasedChainRegistrationSender,
            "v33: CRS alias differs"
        );
        return abi.encode(rebuilt);
    }

    /// @notice v33 force-deploys the system contracts only (see the contract doc).
    function getBaseUniversalForceDeployments(
        uint256,
        address
    ) internal view override returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory) {
        return EraForceDeploymentsLib.wrap(SystemContractsProcessing.getSystemContractsForceDeployments());
    }

    // ======================== Calls ========================

    function _chainAssetHandler() internal view returns (address) {
        return IBridgehubBase(IChainTypeManager(v33Input.ctm).BRIDGE_HUB()).chainAssetHandler();
    }

    function getV33Stage0Calls() public view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: _chainAssetHandler(),
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
        });
    }

    function getV33Stage2Calls() public view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: _chainAssetHandler(),
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
    }

    function getV33Stage1Calls() public view returns (Call[] memory calls) {
        Diamond.DiamondCutData memory upgradeCut = abi.decode(v33UpgradeCut, (Diamond.DiamondCutData));
        ChainCreationParams memory newParams = abi.decode(v33NewChainCreationParams, (ChainCreationParams));
        // setNewVersionUpgrade first: setChainCreationParams keys its block pointer by the version
        // currently set on the CTM, which setNewVersionUpgrade advances (see DefaultCTMUpgrade).
        calls = new Call[](2);
        calls[0] = Call({
            target: v33Input.ctm,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.setNewVersionUpgrade,
                (
                    upgradeCut,
                    v33Input.oldProtocolVersion,
                    UpgradeHelperLib.getOldProtocolDeadline(),
                    v33Input.newProtocolVersion,
                    v33Verifier
                )
            )
        });
        calls[1] = Call({
            target: v33Input.ctm,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setChainCreationParams, (newParams))
        });
    }

    /// @notice The ChainAdmin multicall that upgrades one chain once stage 1 has executed.
    function getV33ChainUpgradeCall(uint256 _chainId) public view returns (address admin, bytes memory data) {
        IChainTypeManager ctm = IChainTypeManager(v33Input.ctm);
        address chain = ctm.getZKChain(_chainId);
        admin = ctm.getChainAdmin(_chainId);
        Diamond.DiamondCutData memory upgradeCut = abi.decode(v33UpgradeCut, (Diamond.DiamondCutData));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chain,
            value: 0,
            data: abi.encodeCall(IAdmin.upgradeChainFromVersion, (chain, v33Input.oldProtocolVersion, upgradeCut))
        });
        data = abi.encodeCall(IChainAdmin.multicall, (calls, true));
    }

    // ======================== Output ========================

    function _saveV33Output(string memory _outputPath) internal {
        Diamond.DiamondCutData memory upgradeCut = abi.decode(v33UpgradeCut, (Diamond.DiamondCutData));
        ChainCreationParams memory newParams = abi.decode(v33NewChainCreationParams, (ChainCreationParams));
        ProposedUpgrade memory proposedUpgrade = abi.decode(_stripSelector(upgradeCut.initCalldata), (ProposedUpgrade));

        vm.serializeUint("contracts_config", "old_protocol_version", v33Input.oldProtocolVersion);
        vm.serializeUint("contracts_config", "new_protocol_version", v33Input.newProtocolVersion);
        vm.serializeAddress("contracts_config", "chain_type_manager", v33Input.ctm);
        vm.serializeAddress("contracts_config", "default_upgrade", v33Input.defaultUpgrade);
        vm.serializeAddress("contracts_config", "bytecodes_supplier", v33Input.bytecodesSupplier);
        vm.serializeAddress("contracts_config", "verifier", v33Verifier);
        vm.serializeBytes32("contracts_config", "bootloader_hash", proposedUpgrade.bootloaderHash);
        vm.serializeBytes32("contracts_config", "default_aa_hash", proposedUpgrade.defaultAccountHash);
        vm.serializeBytes32("contracts_config", "evm_emulator_hash", proposedUpgrade.evmEmulatorHash);
        vm.serializeBytes32("contracts_config", "genesis_root", newParams.genesisBatchHash);
        vm.serializeBytes32("contracts_config", "genesis_batch_commitment", newParams.genesisBatchCommitment);
        vm.serializeBytes32(
            "contracts_config",
            "l2_upgrade_tx_hash",
            keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx))
        );
        bytes32[] memory factoryDeps = new bytes32[](proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps.length);
        uint256 factoryDepCount = factoryDeps.length;
        for (uint256 i = 0; i < factoryDepCount; ++i) {
            factoryDeps[i] = bytes32(proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps[i]);
        }
        vm.serializeBytes32("contracts_config", "l2_upgrade_tx_factory_deps", factoryDeps);
        vm.serializeBytes32("contracts_config", "new_initial_cut_hash", keccak256(abi.encode(newParams.diamondCut)));
        vm.serializeBytes("contracts_config", "upgrade_cut_data", v33UpgradeCut);
        string memory contractsConfig = vm.serializeBytes(
            "contracts_config",
            "new_chain_creation_params",
            v33NewChainCreationParams
        );

        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(getV33Stage0Calls()));
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(getV33Stage1Calls()));
        string memory governanceCalls = vm.serializeBytes(
            "governance_calls",
            "stage2_calls",
            abi.encode(getV33Stage2Calls())
        );

        string memory chainUpgrades = "";
        uint256 chainCount = v33Input.chainIds.length;
        for (uint256 i = 0; i < chainCount; ++i) {
            (address admin, bytes memory data) = getV33ChainUpgradeCall(v33Input.chainIds[i]);
            string memory key = vm.toString(v33Input.chainIds[i]);
            vm.serializeAddress(key, "chain_admin", admin);
            vm.serializeAddress(key, "chain", IChainTypeManager(v33Input.ctm).getZKChain(v33Input.chainIds[i]));
            string memory entry = vm.serializeBytes(key, "chain_admin_calldata", data);
            chainUpgrades = vm.serializeString("chain_upgrades", key, entry);
        }

        vm.serializeString("root", "contracts_config", contractsConfig);
        vm.serializeString("root", "chain_upgrades", chainUpgrades);
        string memory toml = vm.serializeString("root", "governance_calls", governanceCalls);
        vm.writeToml(toml, _outputPath);
        console.log("v33: output written to", _outputPath);
    }

    // ======================== Helpers ========================

    function _decodeChainCreationParamsEvent()
        internal
        view
        returns (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            uint64 genesisIndexRepeatedStorageChanges,
            bytes32 genesisBatchCommitment,
            Diamond.DiamondCutData memory initialCut,
            bytes32 initialCutHash,
            bytes memory forceDeploymentsData,
            bytes32 forceDeploymentHash
        )
    {
        return
            abi.decode(
                v33Input.currentChainCreationParamsEvent,
                (address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
            );
    }

    function _stripSelector(bytes memory _calldata) internal pure returns (bytes memory body) {
        require(_calldata.length >= 4, "v33: calldata too short");
        body = new bytes(_calldata.length - 4);
        uint256 bodyLength = body.length;
        for (uint256 i = 0; i < bodyLength; ++i) {
            body[i] = _calldata[i + 4];
        }
    }
}

/// @dev `FixedForceDeploymentsData` as it was before #2239 removed `gatewayChainId`; the layout of the
///      force-deployment data stage's Era CTM currently stores.
// solhint-disable-next-line gas-struct-packing
struct LegacyFixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 gatewayChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes bridgehubBytecodeInfo;
    bytes l2AssetRouterBytecodeInfo;
    bytes l2NtvBytecodeInfo;
    bytes messageRootBytecodeInfo;
    bytes chainAssetHandlerBytecodeInfo;
    bytes interopCenterBytecodeInfo;
    bytes interopHandlerBytecodeInfo;
    bytes assetTrackerBytecodeInfo;
    bytes beaconDeployerInfo;
    bytes baseTokenHolderBytecodeInfo;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    address aliasedChainRegistrationSender;
    address dangerousTestOnlyForcedBeacon;
    bytes32 zkTokenAssetId;
}

/// @dev `initialForceDeploymentHash` is a public state variable of ChainTypeManagerBase that the
///      IChainTypeManager interface does not expose.
interface IChainTypeManagerV31Views {
    function initialForceDeploymentHash() external view returns (bytes32);
}
