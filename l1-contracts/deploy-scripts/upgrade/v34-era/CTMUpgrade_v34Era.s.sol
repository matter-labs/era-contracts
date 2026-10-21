// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {EraForceDeploymentsLib} from "../default-upgrade/EraForceDeploymentsLib.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {UpgradeUtils} from "../default-upgrade/UpgradeUtils.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

/// @notice v34 Era: moves an Era CTM from v0.33.0 to v0.34.0. From then on every batch needs a Boojum and an
/// Airbender proof; the release also ships the force-fail bootloader, the 15M user L1->L2 gas cap and an EVM
/// emulator fix.
/// @dev Deploys, through CREATE2 with the input's salt: the six facets, `AirbenderVerifierPlonk`, the
/// multi-proof verifier over the live `EraVerifierFflonk` and the new `AirbenderVerifierPlonk`,
/// `EraSettlementLayerV34Upgrade`, and new `EraChainTypeManager` and `ServerNotifier` implementations.
/// Everything else is reused, so the base helpers that would redeploy it (`deployStateTransitionDiamondFacets`,
/// `deployVerifiers`, v31's `deployNewCTMContracts`) are not called. Constructor values come from the input,
/// checked against live state where a getter exists. `initializeWithArgs` is not used: by default, a pre-v31 first
/// chain on the bridgehub (stage's 270) puts its introspection in v29 mode, which zeroes values this upgrade needs.
///
/// Governance, one emergency proposal without a timer: stage 0 pauses migrations; stage 1 upgrades the CTM
/// proxy (the new `ChainCreationParams` only decodes on the new implementation), then calls
/// `setNewVersionUpgrade` and `setChainCreationParams`; stage 2 unpauses. The ServerNotifier upgrade is sent
/// separately, by the owner of its ProxyAdmin.
///
/// The L2 upgrade transaction is v33's: `ContractDeployer.forceDeployOnAddresses` of the 31 system contracts.
/// The three base-system bytecodes come first in its factory deps, which is how the node learns them. It is
/// the same for every chain.
///
/// New chains get the new facets, the reused genesis upgrade and `DiamondInit`, the v34 genesis, and
/// force-deployment data rebuilt with this build's L2 bytecode; its other values are carried over from the
/// CTM's stored copy after checks against the bridgehub and CTM.
///
/// `prepare` broadcasts only the deployments and the factory-dep publication, both permissionless, and writes
/// everything else to the output TOML.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34Era is Script, DefaultCTMUpgrade {
    using stdToml for string;

    /// @notice Parsed input, see `upgrade-envs/v0.34.0-era/<env>.toml`.
    // solhint-disable-next-line gas-struct-packing
    struct V34EraInput {
        address ctm;
        address bytecodesSupplier;
        address permissionlessValidator;
        address chainAssetHandler;
        address rollupDAManager;
        address eip7702Checker;
        address verifierFflonk;
        address diamondInit;
        uint256 eraChainId;
        bool testnetVerifier;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        uint256 upgradeTimestamp;
        bytes32 create2FactorySalt;
        bytes currentChainCreationParamsEvent;
        uint256[] chainIds;
    }

    V34EraInput internal v34Input;
    /// @dev abi-encoded ChainCreationParams (structs with nested dynamic arrays cannot be copied to storage by
    ///      the legacy pipeline).
    bytes internal v34NewChainCreationParams;
    address internal v33Verifier;

    function prepare(string memory _inputPath, string memory _outputPath) public {
        string memory root = vm.projectRoot();
        _loadInput(string.concat(root, _inputPath));
        _checkLiveState();
        _initializeV34Config();

        _deployV34Contracts();
        _checkDeployments();

        // Era invariant checked inside: factory deps [0..2] == genesis bootloader / AA / EVM emulator.
        publishBytecodes();
        console.log("v34: factory dependencies published");

        newlyGeneratedData.upgradeCutData = abi.encode(_buildUpgradeCut());
        v34NewChainCreationParams = abi.encode(_buildNewChainCreationParams());

        string memory outputPath = string.concat(root, _outputPath);
        _saveV34Output(outputPath);
        console.log("v34: output written to", outputPath);
    }

    // ======================== Input and live-state checks ========================

    function _loadInput(string memory _path) internal {
        string memory toml = vm.readFile(_path);
        v34Input.ctm = toml.readAddress("$.ctm");
        v34Input.bytecodesSupplier = toml.readAddress("$.bytecodes_supplier");
        v34Input.permissionlessValidator = toml.readAddress("$.permissionless_validator");
        v34Input.chainAssetHandler = toml.readAddress("$.chain_asset_handler");
        v34Input.rollupDAManager = toml.readAddress("$.rollup_da_manager");
        v34Input.eip7702Checker = toml.readAddress("$.eip7702_checker");
        v34Input.verifierFflonk = toml.readAddress("$.verifier_fflonk");
        v34Input.diamondInit = toml.readAddress("$.diamond_init");
        v34Input.eraChainId = toml.readUint("$.era_chain_id");
        v34Input.testnetVerifier = toml.readBool("$.testnet_verifier");
        v34Input.oldProtocolVersion = toml.readUint("$.old_protocol_version");
        v34Input.newProtocolVersion = toml.readUint("$.new_protocol_version");
        v34Input.upgradeTimestamp = toml.readUint("$.upgrade_timestamp");
        v34Input.create2FactorySalt = toml.readBytes32("$.create2_factory_salt");
        v34Input.currentChainCreationParamsEvent = toml.readBytes("$.current_chain_creation_params_event_data");
        v34Input.chainIds = toml.readUintArray("$.chain_ids");
    }

    /// @dev Fail before deploying anything if the input does not describe the live CTM.
    function _checkLiveState() internal {
        IChainTypeManager ctm = IChainTypeManager(v34Input.ctm);
        require(!ctm.isZKsyncOS(), "v34: not an Era CTM");
        require(ctm.protocolVersion() == v34Input.oldProtocolVersion, "v34: CTM not on old version");
        require(
            UpgradeHelperLib.getProtocolUpgradeNonce(v34Input.newProtocolVersion) ==
                UpgradeHelperLib.getProtocolUpgradeNonce(v34Input.oldProtocolVersion) + 1,
            "v34: new version not next minor"
        );
        require(!UpgradeHelperLib.isPatchUpgrade(v34Input.newProtocolVersion), "v34: must be a minor upgrade");
        require(v34Input.upgradeTimestamp != 0, "v34: zero upgrade timestamp");
        require(v34Input.create2FactorySalt != bytes32(0), "v34: zero salt");

        // The new CTM implementation's constructor arguments are the live CTM's immutables.
        ChainTypeManagerBase liveCtm = ChainTypeManagerBase(v34Input.ctm);
        require(liveCtm.L1_BYTECODES_SUPPLIER() == v34Input.bytecodesSupplier, "v34: supplier is not the CTM's");
        require(
            liveCtm.PERMISSIONLESS_VALIDATOR() == v34Input.permissionlessValidator,
            "v34: permissionless validator is not the CTM's"
        );
        require(liveCtm.INTEROP_CENTER() == L2_INTEROP_CENTER_ADDR, "v34: unexpected interop center");
        require(
            IBridgehubBase(ctm.BRIDGE_HUB()).chainAssetHandler() == v34Input.chainAssetHandler,
            "v34: chain asset handler is not the bridgehub's"
        );

        v33Verifier = ctm.protocolVersionVerifier(v34Input.oldProtocolVersion);
        require(v33Verifier != address(0), "v34: no verifier for old version");
        require(
            ILiveEraVerifier(v33Verifier).IS_TESTNET_VERIFIER() == v34Input.testnetVerifier,
            "v34: testnet flag differs from the live verifier"
        );
        require(
            ILiveEraVerifier(v33Verifier).FFLONK_VERIFIER() == v34Input.verifierFflonk,
            "v34: FFLONK verifier is not the live one"
        );

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
        require(genesisUpgrade == ctm.l1GenesisUpgrade(), "v34: genesis upgrade mismatch");
        require(initialCutHash == ctm.initialCutHash(), "v34: stale creation cut");
        require(keccak256(abi.encode(initialCut)) == initialCutHash, "v34: creation cut hash mismatch");
        require(initialCut.initAddress == v34Input.diamondInit, "v34: diamond init is not the CTM's");
        require(forceDeploymentHash == liveCtm.initialForceDeploymentHash(), "v34: stale force deployments");
        // ChainTypeManagerBase hashes the ABI-encoded bytes, not the raw bytes.
        require(keccak256(abi.encode(forceDeploymentsData)) == forceDeploymentHash, "v34: force deployments hash");

        uint256 chainCount = v34Input.chainIds.length;
        require(chainCount > 0, "v34: no chains");
        for (uint256 i = 0; i < chainCount; ++i) {
            address chain = ctm.getZKChain(v34Input.chainIds[i]);
            require(chain != address(0), "v34: chain not on CTM");
            require(
                IGetters(chain).getProtocolVersion() == v34Input.oldProtocolVersion,
                "v34: chain not on old version"
            );
            require(IGetters(chain).getVerifier() == v33Verifier, "v34: chain verifier is not the CTM's");
        }

        // The new AdminFacet's RollupDAManager must be the one the live facet uses.
        address liveAdminFacet = IGetters(ctm.getZKChain(v34Input.chainIds[0])).facetAddress(
            IAdmin.upgradeChainFromVersion.selector
        );
        require(
            ILiveAdminFacet(liveAdminFacet).ROLLUP_DA_MANAGER() == v34Input.rollupDAManager,
            "v34: rollup DA manager is not the live admin facet's"
        );
        require(v34Input.eip7702Checker.code.length > 0, "v34: EIP-7702 checker has no code");
    }

    /// @dev Sets every value the deployments and calls read.
    function _initializeV34Config() internal {
        setCreate2Salt(v34Input.create2FactorySalt);
        config.l1ChainId = block.chainid;
        config.isZKsyncOS = false;
        config.eraChainId = v34Input.eraChainId;
        config.testnetVerifier = v34Input.testnetVerifier;
        newConfig.oldProtocolVersion = v34Input.oldProtocolVersion;

        IChainTypeManager ctm = IChainTypeManager(v34Input.ctm);
        address bridgehubAddr = ctm.BRIDGE_HUB();
        bridgehub = L1Bridgehub(bridgehubAddr);
        coreAddresses.bridgehub.proxies.bridgehub = bridgehubAddr;
        coreAddresses.bridgehub.proxies.chainAssetHandler = v34Input.chainAssetHandler;

        ctmAddresses.stateTransition.proxies.chainTypeManager = v34Input.ctm;
        ctmAddresses.stateTransition.proxies.bytecodesSupplier = v34Input.bytecodesSupplier;
        ctmAddresses.stateTransition.proxies.permissionlessValidator = v34Input.permissionlessValidator;
        ctmAddresses.stateTransition.proxies.serverNotifier = ctm.serverNotifierAddress();
        ctmAddresses.stateTransition.genesisUpgrade = ctm.l1GenesisUpgrade();
        ctmAddresses.stateTransition.facets.diamondInit = v34Input.diamondInit;
        ctmAddresses.stateTransition.verifiers.verifierFflonk = v34Input.verifierFflonk;
        ctmAddresses.admin.transparentProxyAdmin = Utils.getProxyAdminAddress(v34Input.ctm);
        ctmAddresses.admin.eip7702Checker = v34Input.eip7702Checker;
        ctmAddresses.daAddresses.daContracts.rollupDAManager = v34Input.rollupDAManager;

        // Genesis batch values and base-system hashes come from this branch's Era genesis.
        config.contracts.chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath(false));
        require(
            config.contracts.chainCreationParams.latestProtocolVersion == v34Input.newProtocolVersion,
            "v34: genesis is not for the new version"
        );
    }

    // ======================== Deployments ========================

    function _deployV34Contracts() internal {
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet", false);
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet", false);
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet", false);
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet", false);
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet", false);
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet", false);

        ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk = deploySimpleContract(
            "AirbenderVerifierPlonk",
            false
        );
        (, string memory verifierName) = DeployCTML1OrGateway.resolveChainVerifier(false, config.testnetVerifier);
        ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract(verifierName, false);

        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();

        (, string memory ctmName) = DeployCTML1OrGateway.resolve(false, CTMContract.ChainTypeManager);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmName, false);
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);
    }

    function deployUsedUpgradeContract() internal virtual override returns (address) {
        return deploySimpleContract("EraSettlementLayerV34Upgrade", false);
    }

    /// @dev The deployed contracts must match the live ones they replace, and the verifier must carry the
    ///      genesis VKs.
    function _checkDeployments() internal {
        ChainTypeManagerBase liveCtm = ChainTypeManagerBase(v34Input.ctm);
        ChainTypeManagerBase newCtm = ChainTypeManagerBase(
            ctmAddresses.stateTransition.implementations.chainTypeManager
        );
        require(newCtm.BRIDGE_HUB() == liveCtm.BRIDGE_HUB(), "v34: new CTM BRIDGE_HUB");
        require(newCtm.INTEROP_CENTER() == liveCtm.INTEROP_CENTER(), "v34: new CTM INTEROP_CENTER");
        require(newCtm.L1_BYTECODES_SUPPLIER() == liveCtm.L1_BYTECODES_SUPPLIER(), "v34: new CTM supplier");
        require(
            newCtm.PERMISSIONLESS_VALIDATOR() == liveCtm.PERMISSIONLESS_VALIDATOR(),
            "v34: new CTM permissionless validator"
        );
        require(!newCtm.isZKsyncOS(), "v34: new CTM is not Era");

        address verifier = ctmAddresses.stateTransition.verifiers.verifier;
        require(
            address(IEraMultiProofVerifier(verifier).BOOJUM_VERIFIER()) == v34Input.verifierFflonk,
            "v34: verifier Boojum slot"
        );
        require(
            address(IEraMultiProofVerifier(verifier).AIRBENDER_VERIFIER()) ==
                ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk,
            "v34: verifier Airbender slot"
        );
        require(
            IEraMultiProofVerifier(verifier).IS_TESTNET_VERIFIER() == v34Input.testnetVerifier,
            "v34: verifier testnet flag"
        );
        string memory genesis = vm.readFile(Utils.genesisConfigPath(false));
        require(
            EraMultiProofVerifier(verifier).verificationKeyHash(0) ==
                vm.parseJsonBytes32(genesis, "$.prover.fflonk_snark_wrapper_vk_hash"),
            "v34: Boojum VK is not the genesis one"
        );
        require(
            EraMultiProofVerifier(verifier).verificationKeyHash(2) ==
                vm.parseJsonBytes32(genesis, "$.prover.airbender_snark_wrapper_vk_hash"),
            "v34: Airbender VK is not the genesis one"
        );
    }

    // ======================== Upgrade data ========================

    /// @dev Remove every selector chain `chainIds[0]` routes, add the six new facets, and run
    ///      `EraSettlementLayerV34Upgrade.upgrade(ProposedUpgrade)`.
    function _buildUpgradeCut() internal returns (Diamond.DiamondCutData memory) {
        return
            generateUpgradeCutData({
                _stateTransition: ctmAddresses.stateTransition,
                _chainCreationParams: config.contracts.chainCreationParams,
                _l1ChainId: config.l1ChainId,
                _ownerAddress: address(0),
                _factoryDepsResult: factoryDepsResult,
                _registeredChainIdDiamondProxy: IChainTypeManager(v34Input.ctm).getZKChain(v34Input.chainIds[0])
            });
    }

    /// @dev New facets in the creation cut, the reused genesis upgrade and diamond init, the v34 genesis.
    function _buildNewChainCreationParams() internal returns (ChainCreationParams memory) {
        (, , , , , , bytes memory storedForceDeployments, ) = _decodeChainCreationParamsEvent();
        generatedData.forceDeploymentsData = _rebuildForceDeploymentsData(storedForceDeployments);
        return getChainCreationParams(ctmAddresses.stateTransition);
    }

    /// @dev Rebuild the new-chain force-deployment data with this build's L2 bytecode, carrying the
    ///      non-bytecode values over from the CTM's stored blob. Each carried value is checked against the
    ///      live bridgehub / CTM first.
    function _rebuildForceDeploymentsData(bytes memory _stored) internal returns (bytes memory) {
        FixedForceDeploymentsData memory stored = abi.decode(_stored, (FixedForceDeploymentsData));
        IChainTypeManager ctm = IChainTypeManager(v34Input.ctm);

        address governance = AddressAliasHelper.undoL1ToL2Alias(stored.aliasedL1Governance);
        address chainRegistrationSender = AddressAliasHelper.undoL1ToL2Alias(stored.aliasedChainRegistrationSender);
        require(stored.l1ChainId == block.chainid, "v34: stored l1ChainId mismatch");
        require(stored.eraChainId == v34Input.eraChainId, "v34: stored eraChainId mismatch");
        require(stored.l1AssetRouter == address(bridgehub.assetRouter()), "v34: stored asset router stale");
        require(governance == IOwnable(address(ctm)).owner(), "v34: stored governance stale");
        require(chainRegistrationSender == bridgehub.chainRegistrationSender(), "v34: stored CRS stale");
        require(stored.maxNumberOfZKChains == bridgehub.MAX_NUMBER_OF_ZK_CHAINS(), "v34: stored chain limit stale");
        // The builder hard-codes these to zero; refuse to silently drop a non-zero value.
        require(
            stored.l2SharedBridgeLegacyImpl == address(0) && stored.l2BridgedStandardERC20Impl == address(0),
            "v34: stored legacy impls set"
        );
        require(stored.dangerousTestOnlyForcedBeacon == address(0), "v34: stored test-only beacon set");

        config.contracts.maxNumberOfChains = stored.maxNumberOfZKChains;
        config.zkTokenAssetId = stored.zkTokenAssetId;
        coreAddresses.bridges.proxies.l1AssetRouter = stored.l1AssetRouter;
        coreAddresses.bridgehub.proxies.chainRegistrationSender = chainRegistrationSender;

        FixedForceDeploymentsData memory rebuilt = _buildForceDeploymentsData(governance, address(0));
        require(rebuilt.aliasedL1Governance == stored.aliasedL1Governance, "v34: governance alias differs");
        require(
            rebuilt.aliasedChainRegistrationSender == stored.aliasedChainRegistrationSender,
            "v34: CRS alias differs"
        );
        return abi.encode(rebuilt);
    }

    /// @notice v34 force-deploys the system contracts only, as v33: the L2 core contracts hold live storage.
    function getBaseUniversalForceDeployments(
        uint256,
        address
    ) internal view override returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory) {
        return EraForceDeploymentsLib.wrap(SystemContractsProcessing.getSystemContractsForceDeployments());
    }

    // ======================== Calls ========================

    // The base stages add timer and stage-validator calls; this upgrade deploys neither.
    function prepareStage0GovernanceCalls() public view override returns (Call[] memory calls) {
        calls = preparePauseGatewayMigrationsCall();
    }

    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);
        allCalls[0] = prepareUpgradeCTMCalls();
        allCalls[1] = provideSetNewVersionUpgradeCall();
        allCalls[2] = prepareNewChainCreationParamsCall();
        // The base recomputes the creation params; they must be the ones the output and the test chain use.
        ChainCreationParams memory newParams = abi.decode(v34NewChainCreationParams, (ChainCreationParams));
        require(
            keccak256(allCalls[2][0].data) ==
                keccak256(abi.encodeCall(IChainTypeManager.setChainCreationParams, (newParams))),
            "v34: creation params differ"
        );
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareStage2GovernanceCalls() public view override returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
    }

    /// @notice The call a chain admin makes on the chain's diamond to move it from the old to the new version.
    function _v34UpgradeChainCall(uint256 _chainId) internal view returns (Call memory) {
        address chain = IChainTypeManager(v34Input.ctm).getZKChain(_chainId);
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );
        return
            Call({
                target: chain,
                value: 0,
                data: abi.encodeCall(IAdmin.upgradeChainFromVersion, (chain, v34Input.oldProtocolVersion, upgradeCut))
            });
    }

    /// @notice The ChainAdmin multicall that upgrades one chain once stage 1 has executed.
    function getV34ChainUpgradeCall(uint256 _chainId) public view returns (address admin, bytes memory data) {
        admin = IChainTypeManager(v34Input.ctm).getChainAdmin(_chainId);
        Call[] memory calls = new Call[](1);
        calls[0] = _v34UpgradeChainCall(_chainId);
        data = abi.encodeCall(IChainAdmin.multicall, (calls, true));
    }

    /// @notice The two transactions `protocol_ops chain set-upgrade-timestamp` writes for an Ownable ChainAdmin,
    ///         both sent by its owner to the ChainAdmin: `setUpgradeTimestamp` called directly (it is
    ///         `onlyOwner`; keyed by the new version, read only by pre-v31 nodes), then
    ///         `ServerNotifier.setUpgradeTimestamp` through `multicall` (keyed by the chain's current version,
    ///         read by the node; it reverts until stage 1 has registered the upgrade).
    function getV34ChainTimestampCalldata(
        uint256 _chainId
    ) public view returns (bytes memory setUpgradeTimestamp, bytes memory serverNotifierTimestamp) {
        setUpgradeTimestamp = abi.encodeCall(
            IChainAdminOwnable.setUpgradeTimestamp,
            (v34Input.newProtocolVersion, v34Input.upgradeTimestamp)
        );
        Call[] memory notifierCall = new Call[](1);
        notifierCall[0] = Call({
            target: ctmAddresses.stateTransition.proxies.serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.setUpgradeTimestamp, (_chainId, v34Input.upgradeTimestamp))
        });
        serverNotifierTimestamp = abi.encodeCall(IChainAdmin.multicall, (notifierCall, true));
    }

    /// @notice Test-only: `createNewChain` of a fresh Era chain on the upgraded CTM, from the bridgehub
    ///         admin, with the v34 creation params.
    function getV34TestCreateChainCall() public view returns (address caller, bytes memory data) {
        ChainCreationParams memory newParams = abi.decode(v34NewChainCreationParams, (ChainCreationParams));
        caller = bridgehub.admin();
        data = abi.encodeCall(
            IL1Bridgehub.createNewChain,
            (
                ERA_TEST_CREATE_CHAIN_ID,
                v34Input.ctm,
                bridgehub.baseTokenAssetId(v34Input.chainIds[0]),
                5,
                caller,
                abi.encode(abi.encode(newParams.diamondCut), newParams.forceDeploymentsData),
                new bytes[](0)
            )
        );
    }

    // ======================== Output ========================

    function _saveV34Output(string memory _outputPath) internal {
        vm.serializeString("root", "contracts_config", _serializeContractsConfig());
        vm.serializeString("root", "state_transition", _serializeStateTransition());
        vm.serializeString("root", "deployed_addresses", _serializeDeployedAddresses());
        vm.serializeString("root", "contracts", _serializeCreate2());
        vm.serializeString("root", "governance_calls", _serializeGovernanceCalls());
        vm.serializeString("root", "chain_upgrades", _serializeChainUpgrades());
        string memory toml = vm.serializeString("root", "test_upgrade_calls", _serializeV34TestCalls());
        vm.writeToml(toml, _outputPath);
        // Adds [ctm_admin_calls] to the file just written.
        upgradeConfig.outputPath = _outputPath;
        prepareDefaultCTMAdminCalls();
    }

    function _serializeContractsConfig() internal returns (string memory) {
        bytes memory upgradeCutData = newlyGeneratedData.upgradeCutData;
        Diamond.DiamondCutData memory upgradeCut = abi.decode(upgradeCutData, (Diamond.DiamondCutData));
        ChainCreationParams memory newParams = abi.decode(v34NewChainCreationParams, (ChainCreationParams));
        ProposedUpgrade memory proposedUpgrade = abi.decode(Bytes.slice(upgradeCut.initCalldata, 4), (ProposedUpgrade));
        address verifier = ctmAddresses.stateTransition.verifiers.verifier;

        vm.serializeUint("contracts_config", "old_protocol_version", v34Input.oldProtocolVersion);
        vm.serializeUint("contracts_config", "new_protocol_version", v34Input.newProtocolVersion);
        vm.serializeAddress("contracts_config", "chain_type_manager", v34Input.ctm);
        vm.serializeAddress("contracts_config", "bytecodes_supplier", v34Input.bytecodesSupplier);
        vm.serializeAddress("contracts_config", "verifier", verifier);
        vm.serializeAddress("contracts_config", "old_verifier", v33Verifier);
        // The no-argument VK hash the node stores as the version's snark wrapper key (Boojum FFLONK here).
        vm.serializeBytes32(
            "contracts_config",
            "verifier_vk_hash",
            EraMultiProofVerifier(verifier).verificationKeyHash()
        );
        vm.serializeBytes32(
            "contracts_config",
            "old_verifier_vk_hash",
            ILiveEraVerifier(v33Verifier).verificationKeyHash()
        );
        vm.serializeBytes32("contracts_config", "bootloader_hash", proposedUpgrade.bootloaderHash);
        vm.serializeBytes32("contracts_config", "default_aa_hash", proposedUpgrade.defaultAccountHash);
        vm.serializeBytes32("contracts_config", "evm_emulator_hash", proposedUpgrade.evmEmulatorHash);
        vm.serializeBytes32("contracts_config", "genesis_root", newParams.genesisBatchHash);
        vm.serializeUint("contracts_config", "genesis_rollup_leaf_index", newParams.genesisIndexRepeatedStorageChanges);
        vm.serializeBytes32("contracts_config", "genesis_batch_commitment", newParams.genesisBatchCommitment);
        vm.serializeBytes32(
            "contracts_config",
            "genesis_airbender_batch_commitment",
            newParams.genesisAirbenderBatchCommitment
        );
        vm.serializeBytes32(
            "contracts_config",
            "l2_upgrade_tx_hash",
            keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx))
        );
        vm.serializeBytes32(
            "contracts_config",
            "l2_upgrade_tx_factory_deps",
            UpgradeHelperLib.factoryDepHashes(proposedUpgrade.l2ProtocolUpgradeTx)
        );
        vm.serializeBytes32("contracts_config", "upgrade_cut_hash", keccak256(upgradeCutData));
        vm.serializeBytes32("contracts_config", "new_initial_cut_hash", keccak256(abi.encode(newParams.diamondCut)));
        vm.serializeBytes32(
            "contracts_config",
            "new_force_deployments_hash",
            keccak256(abi.encode(newParams.forceDeploymentsData))
        );
        vm.serializeBytes("contracts_config", "upgrade_cut_data", upgradeCutData);
        return vm.serializeBytes("contracts_config", "new_chain_creation_params", v34NewChainCreationParams);
    }

    /// @dev Every state-transition address the upgrade deploys or reuses, under `DefaultCTMUpgrade.saveOutput`'s
    ///      keys (v31's `[ctms.era.state_transition]`).
    function _serializeStateTransition() internal returns (string memory) {
        StateTransitionDeployedAddresses memory st = ctmAddresses.stateTransition;
        vm.serializeAddress("state_transition", "admin_facet_addr", st.facets.adminFacet);
        vm.serializeAddress("state_transition", "getters_facet_addr", st.facets.gettersFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", st.facets.mailboxFacet);
        vm.serializeAddress("state_transition", "executor_facet_addr", st.facets.executorFacet);
        vm.serializeAddress("state_transition", "migrator_facet_addr", st.facets.migratorFacet);
        vm.serializeAddress("state_transition", "committer_facet_addr", st.facets.committerFacet);
        vm.serializeAddress("state_transition", "diamond_init_addr", st.facets.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", st.genesisUpgrade);
        vm.serializeAddress("state_transition", "default_upgrade_addr", st.defaultUpgrade);
        vm.serializeAddress("state_transition", "verifier_addr", st.verifiers.verifier);
        vm.serializeAddress("state_transition", "verifier_fflonk_addr", st.verifiers.verifierFflonk);
        vm.serializeAddress("state_transition", "airbender_verifier_addr", st.verifiers.airbenderVerifierPlonk);
        vm.serializeAddress("state_transition", "chain_type_manager_proxy", st.proxies.chainTypeManager);
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_implementation_addr",
            st.implementations.chainTypeManager
        );
        vm.serializeAddress(
            "state_transition",
            "server_notifier_implementation_addr",
            st.implementations.serverNotifier
        );
        vm.serializeAddress("state_transition", "bytecodes_supplier_addr", st.proxies.bytecodesSupplier);
        vm.serializeAddress("state_transition", "permissionless_validator_addr", st.proxies.permissionlessValidator);
        return vm.serializeAddress("state_transition", "eip7702_checker_addr", ctmAddresses.admin.eip7702Checker);
    }

    /// @dev Other addresses the calls and constructors use, under the keys of `DefaultCTMUpgrade.saveOutput`
    ///      and `DeployCTM.saveOutput`.
    function _serializeDeployedAddresses() internal returns (string memory) {
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin", ctmAddresses.admin.transparentProxyAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_proxy_addr",
            ctmAddresses.stateTransition.proxies.serverNotifier
        );
        return
            vm.serializeAddress(
                "deployed_addresses",
                "l1_rollup_da_manager",
                ctmAddresses.daAddresses.daContracts.rollupDAManager
            );
    }

    /// @dev The CREATE2 factory and the salt every deployment used, under `DeployCTM.saveOutput`'s keys.
    function _serializeCreate2() internal returns (string memory) {
        (address factory, bytes32 salt) = getCreate2FactoryParams();
        vm.serializeAddress("contracts", "create2_factory_addr", factory);
        return vm.serializeBytes32("contracts", "create2_factory_salt", salt);
    }

    function _serializeGovernanceCalls() internal returns (string memory) {
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(prepareStage0GovernanceCalls()));
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(prepareStage1GovernanceCalls()));
        return vm.serializeBytes("governance_calls", "stage2_calls", abi.encode(prepareStage2GovernanceCalls()));
    }

    function _serializeChainUpgrades() internal returns (string memory chainUpgrades) {
        uint256 chainCount = v34Input.chainIds.length;
        for (uint256 i = 0; i < chainCount; ++i) {
            string memory key = vm.toString(v34Input.chainIds[i]);
            chainUpgrades = vm.serializeString("chain_upgrades", key, _serializeChainUpgrade(v34Input.chainIds[i]));
        }
    }

    /// @dev Raw calldata the chain's ChainAdmin owner sends to the ChainAdmin, in this order:
    ///      `set_upgrade_timestamp_calldata` and `server_notifier_timestamp_calldata` after stage 1, then
    ///      `chain_admin_calldata` (the upgrade) once the chain is drained.
    function _serializeChainUpgrade(uint256 _chainId) internal returns (string memory) {
        string memory key = vm.toString(_chainId);
        (address admin, bytes memory upgradeCalldata) = getV34ChainUpgradeCall(_chainId);
        (bytes memory setTimestamp, bytes memory notifierTimestamp) = getV34ChainTimestampCalldata(_chainId);
        vm.serializeAddress(key, "chain", IChainTypeManager(v34Input.ctm).getZKChain(_chainId));
        vm.serializeAddress(key, "chain_admin", admin);
        vm.serializeAddress(key, "chain_admin_owner", IOwnable(admin).owner());
        vm.serializeBytes(key, "set_upgrade_timestamp_calldata", setTimestamp);
        vm.serializeBytes(key, "server_notifier_timestamp_calldata", notifierTimestamp);
        return vm.serializeBytes(key, "chain_admin_calldata", upgradeCalldata);
    }

    /// @dev Test-only calls in the `[test_upgrade_calls]` layout the transaction simulator reads: each value
    /// is an ABI-encoded `Call[]` sent by the matching `*_caller`.
    function _serializeV34TestCalls() internal returns (string memory) {
        (address createChainCaller, bytes memory createChainData) = getV34TestCreateChainCall();
        Call[] memory createChain = new Call[](1);
        createChain[0] = Call({target: address(bridgehub), value: 0, data: createChainData});
        Call[] memory upgradeChain = new Call[](1);
        upgradeChain[0] = _v34UpgradeChainCall(v34Input.chainIds[0]);

        vm.serializeBytes("test_upgrade_calls", "test_create_chain_era", abi.encode(createChain));
        vm.serializeAddress("test_upgrade_calls", "test_create_chain_era_caller", createChainCaller);
        vm.serializeBytes("test_upgrade_calls", "test_upgrade_chain_era", abi.encode(upgradeChain));
        return
            vm.serializeAddress(
                "test_upgrade_calls",
                "test_upgrade_chain_era_caller",
                IChainTypeManager(v34Input.ctm).getChainAdmin(v34Input.chainIds[0])
            );
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
                v34Input.currentChainCreationParamsEvent,
                (address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
            );
    }
}

/// @dev The pre-v34 Era verifier (`EraTestnetVerifier` / `EraDualVerifier`) the CTM runs for v0.33.0.
interface ILiveEraVerifier {
    // solhint-disable-next-line func-name-mixedcase
    function FFLONK_VERIFIER() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function IS_TESTNET_VERIFIER() external view returns (bool);
    function verificationKeyHash() external view returns (bytes32);
}

/// @dev The live AdminFacet's public immutable.
interface ILiveAdminFacet {
    // solhint-disable-next-line func-name-mixedcase
    function ROLLUP_DA_MANAGER() external view returns (address);
}
