// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {V34EraOutputChecks} from "./V34EraOutputChecks.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {
    AIRBENDER_PROOF_SYSTEM_MASK,
    BOOJUM_PROOF_SYSTEM_MASK,
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    DisabledProofSystems,
    EMPTY_STRING_KECCAK,
    ProofSystem,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    TX_SLOT_OVERHEAD_L2_GAS,
    USER_PRIORITY_TX_MAX_GAS_LIMIT
} from "contracts/common/Config.sol";
import {
    InvalidDisabledProofSystemsMask,
    SlotOccupied,
    TooMuchGas,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IServerNotifier} from "contracts/governance/IServerNotifier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";

/// @title V34EraUpgradeForkTest
/// @notice v34 Era checks on protocol-ops' replayed fork (`fork_tests`).
/// @dev The L1 before the upgrade is read on a fork of `FORK_URL` at `FORK_BLOCK`: concurrent reads below the
/// replayed fork's head deadlock its Anvil (see protocol-ops' `run_fork_tests`).
contract V34EraUpgradeForkTest is Test {
    string internal constant ALL_CONTRACTS_HASHES = "/../AllContractsHashes.json";
    /// @dev v0.33.0's L2 upgrade tx, whose force deployments v34 keeps: the same for every env.
    string internal constant V33_STAGE_OUTPUT = "/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml";
    /// @dev The largest deposit `l2GasLimit` the cap admits: it bounds the body, and a deposit without calldata or
    /// factory deps carries the slot overhead.
    uint256 internal constant CAP_L2_GAS_LIMIT = USER_PRIORITY_TX_MAX_GAS_LIMIT + TX_SLOT_OVERHEAD_L2_GAS;
    /// @dev Any price works as long as the mint covers the base cost at it.
    uint256 internal constant DEPOSIT_GAS_PRICE = 100 gwei;
    /// @dev `EraMultiProofVerifier`'s verification types.
    uint256 internal constant BOOJUM_VERIFICATION_TYPE = 0;
    uint256 internal constant AIRBENDER_VERIFICATION_TYPE = 2;
    /// @dev `ServerNotifier`'s `Initializable._initialized`: slot 1, byte 20, packed after `_pendingOwner`.
    bytes32 internal constant SERVER_NOTIFIER_INITIALIZED_SLOT = bytes32(uint256(1));
    uint256 internal constant SERVER_NOTIFIER_INITIALIZED_SHIFT = 20 * 8;

    string internal forkUrl;
    uint256 internal forkBlock;
    uint256 internal referenceChainId;
    uint256 internal testChainId;
    string internal checksDir;
    string internal envTomlPath;
    string internal permanentTomlPath;
    IL1Bridgehub internal bridgehub;
    IChainTypeManager internal ctm;
    uint256 internal replayedFork;

    function setUp() public {
        checksDir = vm.envOr("CHECKS_DIR", string(""));
        if (bytes(checksDir).length == 0) {
            vm.skip(true, "no CHECKS_DIR: protocol-ops' fork_tests run this on the fork it replayed the upgrade on");
        }
        forkUrl = vm.envString("FORK_URL");
        forkBlock = vm.envUint("FORK_BLOCK");
        referenceChainId = vm.envUint("REFERENCE_CHAIN_ID");
        testChainId = vm.envUint("TEST_CHAIN_ID");
        string memory env = vm.envString("UPGRADE_ENV");
        envTomlPath = string.concat(vm.projectRoot(), "/upgrade-envs/v0.34.0-era/", env, ".toml");
        permanentTomlPath = string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/", env, ".toml");
        // The script's CTM: the first one, which must be Era.
        string memory permanent = vm.readFile(permanentTomlPath);
        assertFalse(vm.parseTomlBool(permanent, "$.ctm_contracts.ctms[0].is_zk_sync_os"), "the first CTM is Era");
        bridgehub = IL1Bridgehub(vm.parseTomlAddress(permanent, "$.core_contracts.bridgehub_proxy_addr"));
        ctm = IChainTypeManager(vm.parseTomlAddress(permanent, "$.ctm_contracts.ctms[0].proxy"));
        replayedFork = vm.activeFork();
    }

    // ─── The output ──────────────────────────────────────────────────────────────────

    function test_outputMatchesTheEnvironment() public {
        V34EraOutputChecks.Output memory out = _output();
        (bytes32 salt, V34EraOutputChecks.Deployment[] memory deployments) = V34EraOutputChecks.readDeployments(
            vm.readFile(string.concat(checksDir, "/deployments.json"))
        );
        V34EraOutputChecks.check(out, salt, deployments, _references());
    }

    /// @dev Only this CTM's chains are called: a legacy chain may revert a call to its diamond.
    function test_referenceChainIsTheScriptsPick() public {
        vm.createSelectFork(forkUrl, forkBlock);
        uint256 oldVersion = ctm.protocolVersion();
        uint256[] memory chainIds = bridgehub.getAllZKChainChainIDs();
        uint256 first = 0;
        bool found = false;
        for (uint256 i = 0; i < chainIds.length && !found; ++i) {
            if (bridgehub.chainTypeManager(chainIds[i]) == address(ctm)) {
                found = IGetters(bridgehub.getZKChain(chainIds[i])).getProtocolVersion() == oldVersion;
                first = chainIds[i];
            }
        }
        assertTrue(found, "a chain of the CTM on its version at FORK_BLOCK");
        assertEq(referenceChainId, first, "REFERENCE_CHAIN_ID = the bridgehub's first chain of the CTM on its version");
    }

    // ─── The CTM and the ServerNotifier ──────────────────────────────────────────────

    function test_ctmAndServerNotifierAfterTheStages() public {
        V34EraOutputChecks.Output memory out = _output();
        string memory genesis = vm.readFile(Utils.genesisConfigPath(false));
        IOwnable serverNotifier = IOwnable(ctm.serverNotifierAddress());
        vm.createSelectFork(forkUrl, forkBlock);
        address ownerBefore = serverNotifier.owner();
        address ctmBefore = address(ServerNotifier(address(serverNotifier)).chainTypeManager());
        vm.selectFork(replayedFork);
        assertEq(serverNotifier.owner(), ownerBefore, "ServerNotifier owner unchanged");
        assertEq(
            address(ServerNotifier(address(serverNotifier)).chainTypeManager()),
            ctmBefore,
            "ServerNotifier chainTypeManager unchanged"
        );

        EraMultiProofVerifier verifier = EraMultiProofVerifier(ctm.protocolVersionVerifier(out.newProtocolVersion));
        assertEq(
            verifier.IS_TESTNET_VERIFIER(),
            vm.parseTomlBool(vm.readFile(envTomlPath), "$.testnet_verifier"),
            "verifier: testnet flag = the env's testnet_verifier"
        );
        assertEq(address(verifier.BOOJUM_VERIFIER()), out.addresses.verifierFflonk, "verifier: Boojum verifier");
        assertEq(
            address(verifier.AIRBENDER_VERIFIER()),
            out.addresses.airbenderVerifier,
            "verifier: Airbender verifier"
        );
        assertEq(
            verifier.verificationKeyHash(BOOJUM_VERIFICATION_TYPE),
            vm.parseJsonBytes32(genesis, "$.prover.fflonk_snark_wrapper_vk_hash"),
            "verifier: Boojum VK = the genesis one"
        );
        assertEq(
            verifier.verificationKeyHash(AIRBENDER_VERIFICATION_TYPE),
            vm.parseJsonBytes32(genesis, "$.prover.airbender_snark_wrapper_vk_hash"),
            "verifier: Airbender VK = the genesis one"
        );
        assertEq(ctm.l1GenesisUpgrade(), out.addresses.genesisUpgrade, "CTM l1GenesisUpgrade");
        assertEq(ctm.storedBatchZero(), keccak256(abi.encode(_batchZero(_genesis(genesis)))), "CTM storedBatchZero");

        address[4] memory owned = [
            address(ctm),
            out.addresses.ctmImplementation,
            address(serverNotifier),
            out.addresses.serverNotifierImplementation
        ];
        for (uint256 i = 0; i < owned.length; ++i) {
            assertEq(IOwnable(owned[i]).pendingOwner(), address(0), "no pending owner");
        }

        // None can be initialized again.
        ChainTypeManagerInitializeData memory init;
        init.owner = address(this);
        vm.expectRevert(SlotOccupied.selector);
        ctm.initialize(init);
        vm.expectRevert(SlotOccupied.selector);
        IChainTypeManager(out.addresses.ctmImplementation).initialize(init);
        // A proxy initialized before `initialize` took `initializer` (mainnet's) has `_initialized` 0: only the
        // reentrancy guard stops a second call. The implementation's disabled initializers pin the slot and offset.
        assertEq(
            _serverNotifierInitialized(out.addresses.serverNotifierImplementation),
            type(uint8).max,
            "ServerNotifier implementation: _initialized at its slot and offset"
        );
        if (_serverNotifierInitialized(address(serverNotifier)) == 0) {
            vm.expectRevert(SlotOccupied.selector);
        } else {
            vm.expectRevert("Initializable: contract is already initialized");
        }
        ServerNotifier(address(serverNotifier)).initialize(address(this));
        vm.expectRevert("Initializable: contract is already initialized");
        ServerNotifier(out.addresses.serverNotifierImplementation).initialize(address(this));
    }

    // ─── The chains ──────────────────────────────────────────────────────────────────

    function test_upgradedChainsState() public {
        V34EraOutputChecks.Output memory out = _output();
        Diamond.DiamondCutData memory cut = abi.decode(out.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        V34EraOutputChecks.Genesis memory genesis = _genesis(vm.readFile(Utils.genesisConfigPath(false)));
        _checkChainState(referenceChainId, out, cut, genesis);
        _checkChainState(testChainId, out, cut, genesis);
        IZKChain chain = _chain(referenceChainId);
        assertEq(
            chain.getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(V34EraOutputChecks.proposedUpgrade(cut).l2ProtocolUpgradeTx)),
            "reference chain: the pending L2 upgrade tx is the cut's"
        );
        vm.createSelectFork(forkUrl, forkBlock);
        uint256 limitBefore = chain.getPriorityTxMaxGasLimit();
        vm.selectFork(replayedFork);
        assertEq(chain.getPriorityTxMaxGasLimit(), limitBefore, "reference chain: priorityTxMaxGasLimit unchanged");
    }

    /// @dev Before v34 the reference chain takes a deposit over the cap.
    function test_capIsNewInV34() public {
        vm.createSelectFork(forkUrl, forkBlock);
        _deposit(referenceChainId, CAP_L2_GAS_LIMIT + 1);
    }

    function test_userPriorityTxGasLimitCap() public {
        (address depositor, uint256 mint, L2TransactionRequestDirect memory request) = _depositRequest(
            referenceChainId,
            CAP_L2_GAS_LIMIT + 1
        );
        vm.expectRevert(TooMuchGas.selector);
        vm.prank(depositor, depositor);
        bridgehub.requestL2TransactionDirect{value: mint}(request);
        _deposit(referenceChainId, CAP_L2_GAS_LIMIT);
    }

    /// @dev As the chain's `getAdmin()`, the ChainAdmin: announce to the server, then switch. Boojum and Airbender
    /// can't both go.
    function test_proofSystemSwitches() public {
        IZKChain chain = _chain(referenceChainId);
        IServerNotifier serverNotifier = IServerNotifier(ctm.serverNotifierAddress());
        address admin = chain.getAdmin();
        uint8 both = BOOJUM_PROOF_SYSTEM_MASK | AIRBENDER_PROOF_SYSTEM_MASK;
        assertEq(IEraMultiProofVerifier(chain.getVerifier()).supportedProofSystems(), both, "both proof systems");

        DisabledProofSystems memory withoutAirbender = DisabledProofSystems({boojum: false, airbender: true});
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        chain.setProofSystemStatus(ProofSystem.Airbender, false);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        serverNotifier.notifyProofSystemStatus(referenceChainId, withoutAirbender);

        _switchAirbender(chain, serverNotifier, admin, false);
        DisabledProofSystems memory disabled = chain.disabledProofSystems();
        assertTrue(!disabled.boojum && disabled.airbender, "Airbender disabled");

        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, both));
        vm.prank(admin);
        chain.setProofSystemStatus(ProofSystem.Boojum, false);

        _switchAirbender(chain, serverNotifier, admin, true);
        disabled = chain.disabledProofSystems();
        assertTrue(!disabled.boojum && !disabled.airbender, "both enabled again");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────────

    function _output() internal view returns (V34EraOutputChecks.Output memory) {
        return V34EraOutputChecks.readOutput(vm.readFile(string.concat(checksDir, "/ecosystem.toml")));
    }

    function _chain(uint256 _chainId) internal view returns (IZKChain) {
        return IZKChain(bridgehub.getZKChain(_chainId));
    }

    function _serverNotifierInitialized(address _serverNotifier) internal view returns (uint8) {
        return
            uint8(
                uint256(vm.load(_serverNotifier, SERVER_NOTIFIER_INITIALIZED_SLOT)) >> SERVER_NOTIFIER_INITIALIZED_SHIFT
            );
    }

    function _references() internal returns (V34EraOutputChecks.References memory refs) {
        string memory env = vm.readFile(envTomlPath);
        refs.isTestnet = vm.parseTomlBool(env, "$.testnet_verifier");
        refs.timerDelay = vm.parseTomlUint(env, "$.governance_upgrade_timer_initial_delay");
        refs.salt = vm.parseTomlBytes32(env, "$.create2_factory_salt");
        string memory genesis = vm.readFile(Utils.genesisConfigPath(false));
        refs.newProtocolVersion = SemVer.packSemVer(
            uint32(vm.parseJsonUint(genesis, "$.protocol_semantic_version.major")),
            uint32(vm.parseJsonUint(genesis, "$.protocol_semantic_version.minor")),
            uint32(vm.parseJsonUint(genesis, "$.protocol_semantic_version.patch"))
        );
        refs.genesis = _genesis(genesis);
        refs.l2 = _l2Bytecodes(refs.genesis);
        vm.createSelectFork(forkUrl, forkBlock);
        refs.oldProtocolVersion = ctm.protocolVersion();
        refs.l1 = _l1Facts();
        vm.selectFork(replayedFork);
    }

    /// @dev Read as the script reads them.
    function _l1Facts() internal view returns (V34EraOutputChecks.L1Facts memory l1) {
        string memory permanent = vm.readFile(permanentTomlPath);
        l1.l1ChainId = vm.parseTomlUint(permanent, "$.l1_chain_id");
        l1.zkTokenAssetId = vm.parseTomlBytes32(permanent, "$.zk_token_asset_id");
        l1.bridgehub = address(bridgehub);
        l1.ctm = address(ctm);
        l1.l1AssetRouter = address(bridgehub.assetRouter());
        l1.eraChainId = IL1AssetRouter(l1.l1AssetRouter).ERA_CHAIN_ID();
        l1.maxNumberOfZKChains = L1Bridgehub(address(bridgehub)).MAX_NUMBER_OF_ZK_CHAINS();
        l1.chainAssetHandler = bridgehub.chainAssetHandler();
        l1.chainRegistrationSender = bridgehub.chainRegistrationSender();
        l1.ecosystemAdmin = bridgehub.admin();
        l1.ecosystemAdminOwner = IOwnable(l1.ecosystemAdmin).owner();
        l1.ctmOwner = IOwnable(address(ctm)).owner();
        l1.ctmProxyAdmin = Utils.getProxyAdminAddress(address(ctm));
        l1.bytecodesSupplier = ChainTypeManagerBase(address(ctm)).L1_BYTECODES_SUPPLIER();
        l1.permissionlessValidator = ctm.PERMISSIONLESS_VALIDATOR();
        l1.interopCenter = ChainTypeManagerBase(address(ctm)).INTEROP_CENTER();
        l1.genesisUpgrade = ctm.l1GenesisUpgrade();
        l1.serverNotifier = ctm.serverNotifierAddress();
        l1.serverNotifierProxyAdmin = Utils.getProxyAdminAddress(l1.serverNotifier);
        l1.referenceChain = bridgehub.getZKChain(referenceChainId);
        l1.referenceChainAdmin = ctm.getChainAdmin(referenceChainId);
        l1.rollupDAManager = IAdmin(l1.referenceChain).getRollupDAManager();
        l1.referenceChainSelectors = _selectors(IGetters(l1.referenceChain).facets());
        l1.testChainId = testChainId;
    }

    function _genesis(string memory _json) internal pure returns (V34EraOutputChecks.Genesis memory) {
        return
            V34EraOutputChecks.Genesis({
                bootloaderHash: vm.parseJsonBytes32(_json, "$.bootloader_hash"),
                defaultAccountHash: vm.parseJsonBytes32(_json, "$.default_aa_hash"),
                evmEmulatorHash: vm.parseJsonBytes32(_json, "$.evm_emulator_hash"),
                root: vm.parseJsonBytes32(_json, "$.genesis_root"),
                leafIndex: uint64(vm.parseJsonUint(_json, "$.genesis_rollup_leaf_index")),
                batchCommitment: vm.parseJsonBytes32(_json, "$.genesis_batch_commitment"),
                airbenderBatchCommitment: vm.parseJsonBytes32(_json, "$.genesis_airbender_batch_commitment")
            });
    }

    /// @dev v33's force deployments with v34's two changes, the factory deps, the BeaconProxy and new chains'
    /// bytecode infos, all at this build.
    function _l2Bytecodes(
        V34EraOutputChecks.Genesis memory _genesisValues
    ) internal view returns (V34EraOutputChecks.L2Bytecodes memory l2) {
        string memory hashes = vm.readFile(string.concat(vm.projectRoot(), ALL_CONTRACTS_HASHES));
        string[] memory names = _contractNames(hashes);
        l2.forceDeployments = _v34ForceDeployments(hashes, names);
        string[] memory core = _coreContracts();
        uint256 n = l2.forceDeployments.length;
        uint256 base = V34EraOutputChecks.BASE_SYSTEM_FACTORY_DEPS;
        l2.factoryDeps = new bytes32[](base + n + core.length);
        (l2.factoryDeps[0], l2.factoryDeps[1], l2.factoryDeps[2]) = (
            _genesisValues.bootloaderHash,
            _genesisValues.defaultAccountHash,
            _genesisValues.evmEmulatorHash
        );
        for (uint256 i = 0; i < n; ++i) {
            l2.factoryDeps[base + i] = l2.forceDeployments[i].bytecodeHash;
        }
        for (uint256 i = 0; i < core.length; ++i) {
            l2.factoryDeps[base + n + i] = _zkHash(hashes, names, core[i]);
        }
        l2.beaconProxy = _zkHash(hashes, names, "l1-contracts/BeaconProxy");
        string[] memory infos = _bytecodeInfoContracts();
        l2.bytecodeInfos = new bytes32[](infos.length);
        for (uint256 i = 0; i < infos.length; ++i) {
            l2.bytecodeInfos[i] = _zkHash(hashes, names, infos[i]);
        }
    }

    function _v34ForceDeployments(
        string memory _hashes,
        string[] memory _names
    ) internal view returns (IL2ContractDeployer.ForceDeployment[] memory deployments) {
        string memory v33 = vm.readFile(string.concat(vm.projectRoot(), V33_STAGE_OUTPUT));
        Diamond.DiamondCutData memory v33Cut = abi.decode(
            vm.parseTomlBytes(v33, "$.contracts_config.upgrade_cut_data"),
            (Diamond.DiamondCutData)
        );
        deployments = V34EraOutputChecks.forceDeployments(
            V34EraOutputChecks.proposedUpgrade(v33Cut).l2ProtocolUpgradeTx.data
        );
        uint256 replaced = 0;
        for (uint256 i = 0; i < deployments.length; ++i) {
            if (deployments[i].newAddress == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
                deployments[i].bytecodeHash = _zkHash(_hashes, _names, "l1-contracts/L2BaseTokenEra");
                ++replaced;
            } else if (deployments[i].newAddress == L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR) {
                deployments[i].bytecodeHash = _zkHash(_hashes, _names, "l1-contracts/SystemContractProxyAdmin");
                ++replaced;
            }
        }
        assertEq(replaced, 2, "v33's force deployments hold 0x800A and 0x1000c once each");
        // Every entry's zk hash, with a zero for the L1-only contracts.
        bytes32[] memory known = abi.decode(vm.parseJson(_hashes, "$[*].zkBytecodeHash"), (bytes32[]));
        for (uint256 i = 0; i < deployments.length; ++i) {
            bytes32 hash = deployments[i].bytecodeHash;
            bool found = false;
            for (uint256 j = 0; j < known.length && !found; ++j) {
                found = hash != bytes32(0) && known[j] == hash;
            }
            assertTrue(
                found,
                string.concat("force deployment at ", vm.toString(deployments[i].newAddress), ": this build's")
            );
        }
    }

    /// @dev The L2 core contracts' bytecodes the L2 upgrade tx publishes besides the force-deployed ones.
    function _coreContracts() internal pure returns (string[] memory names) {
        names = new string[](18);
        names[0] = "l1-contracts/L2Bridgehub";
        names[1] = "l1-contracts/L2AssetRouter";
        names[2] = "l1-contracts/L2NativeTokenVault";
        names[3] = "l1-contracts/L2MessageRoot";
        names[4] = "l1-contracts/L2MessageVerification";
        names[5] = "l1-contracts/L2ChainAssetHandler";
        names[6] = "l1-contracts/L2InteropRootStorage";
        names[7] = "l1-contracts/BaseTokenHolder";
        names[8] = "l1-contracts/L2AssetTracker";
        names[9] = "l1-contracts/InteropCenter";
        names[10] = "l1-contracts/InteropHandler";
        names[11] = "l1-contracts/GWAssetTracker";
        names[12] = "l1-contracts/TransparentUpgradeableProxy";
        names[13] = "l1-contracts/BeaconProxy";
        names[14] = "l1-contracts/L2SharedBridgeLegacy";
        names[15] = "l1-contracts/BridgedStandardERC20";
        names[16] = "l1-contracts/DiamondProxy";
        names[17] = "l1-contracts/ProxyAdmin";
    }

    /// @dev `FixedForceDeploymentsData`'s bytecode infos, in field order.
    function _bytecodeInfoContracts() internal pure returns (string[] memory names) {
        names = new string[](10);
        names[0] = "l1-contracts/L2Bridgehub";
        names[1] = "l1-contracts/L2AssetRouter";
        names[2] = "l1-contracts/L2NativeTokenVault";
        names[3] = "l1-contracts/L2MessageRoot";
        names[4] = "l1-contracts/L2ChainAssetHandler";
        names[5] = "l1-contracts/InteropCenter";
        names[6] = "l1-contracts/InteropHandler";
        names[7] = "l1-contracts/L2AssetTracker";
        names[8] = "l1-contracts/UpgradeableBeaconDeployer";
        names[9] = "l1-contracts/BaseTokenHolder";
    }

    /// @dev `AllContractsHashes.json`'s names, in its order.
    function _contractNames(string memory _hashes) internal pure returns (string[] memory) {
        return abi.decode(vm.parseJson(_hashes, "$[*].contractName"), (string[]));
    }

    function _zkHash(
        string memory _hashes,
        string[] memory _names,
        string memory _name
    ) internal pure returns (bytes32) {
        uint256 found = 0;
        uint256 at = 0;
        for (uint256 i = 0; i < _names.length; ++i) {
            if (keccak256(bytes(_names[i])) == keccak256(bytes(_name))) {
                ++found;
                at = i;
            }
        }
        assertEq(found, 1, string.concat(_name, " once in AllContractsHashes.json"));
        return vm.parseJsonBytes32(_hashes, string.concat("$[", vm.toString(at), "].zkBytecodeHash"));
    }

    function _selectors(IGetters.Facet[] memory _facets) internal pure returns (bytes4[] memory selectors) {
        uint256 total = 0;
        for (uint256 i = 0; i < _facets.length; ++i) {
            total += _facets[i].selectors.length;
        }
        selectors = new bytes4[](total);
        uint256 next = 0;
        for (uint256 i = 0; i < _facets.length; ++i) {
            for (uint256 j = 0; j < _facets[i].selectors.length; ++j) {
                selectors[next++] = _facets[i].selectors[j];
            }
        }
    }

    /// @dev As `ChainTypeManagerBase` stores it for the new chain creation params.
    function _batchZero(
        V34EraOutputChecks.Genesis memory _genesisValues
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        return
            IExecutor.StoredBatchInfo({
                batchNumber: 0,
                batchHash: _genesisValues.root,
                indexRepeatedStorageChanges: _genesisValues.leafIndex,
                numberOfLayer1Txs: 0,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                dependencyRootsRollingHash: bytes32(0),
                l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
                timestamp: 0,
                commitment: _genesisValues.batchCommitment,
                airbenderCommitment: _genesisValues.airbenderBatchCommitment
            });
    }

    function _checkChainState(
        uint256 _chainId,
        V34EraOutputChecks.Output memory _out,
        Diamond.DiamondCutData memory _cut,
        V34EraOutputChecks.Genesis memory _genesisValues
    ) internal view {
        IZKChain chain = _chain(_chainId);
        string memory label = string.concat("chain ", vm.toString(_chainId), ": ");
        assertEq(chain.getProtocolVersion(), _out.newProtocolVersion, string.concat(label, "protocol version"));
        assertEq(
            chain.getL2BootloaderBytecodeHash(),
            _genesisValues.bootloaderHash,
            string.concat(label, "bootloader")
        );
        assertEq(
            chain.getL2DefaultAccountBytecodeHash(),
            _genesisValues.defaultAccountHash,
            string.concat(label, "default account")
        );
        assertEq(
            chain.getL2EvmEmulatorBytecodeHash(),
            _genesisValues.evmEmulatorHash,
            string.concat(label, "EVM emulator")
        );
        assertEq(chain.getVerifier(), _out.addresses.verifier, string.concat(label, "verifier"));
        DisabledProofSystems memory disabled = chain.disabledProofSystems();
        assertTrue(!disabled.boojum && !disabled.airbender, string.concat(label, "no proof system disabled"));
        assertEq(
            chain.getUserPriorityTxMaxGasLimit(),
            USER_PRIORITY_TX_MAX_GAS_LIMIT,
            string.concat(label, "user priority tx gas cap")
        );
        // The cut's Adds exactly: each facet routes its selectors with its freezable flag.
        Diamond.FacetCut[] memory adds = V34EraOutputChecks.adds(_cut);
        assertEq(chain.facets().length, adds.length, string.concat(label, "facets = the cut's Adds"));
        for (uint256 i = 0; i < adds.length; ++i) {
            assertEq(
                chain.facetFunctionSelectors(adds[i].facet).length,
                adds[i].selectors.length,
                string.concat(label, "a facet's selectors")
            );
            for (uint256 j = 0; j < adds[i].selectors.length; ++j) {
                assertEq(chain.facetAddress(adds[i].selectors[j]), adds[i].facet, string.concat(label, "selector"));
                assertEq(
                    chain.isFunctionFreezable(adds[i].selectors[j]),
                    adds[i].isFreezable,
                    string.concat(label, "freezable flag")
                );
            }
        }
    }

    /// @dev From a fresh EOA, refunds to it, with a mint that covers a deposit just over the cap.
    function _depositRequest(
        uint256 _chainId,
        uint256 _l2GasLimit
    ) internal returns (address depositor, uint256 mint, L2TransactionRequestDirect memory request) {
        depositor = makeAddr("v34 fork test depositor");
        assertEq(depositor.code.length, 0, "the depositor is an EOA");
        mint = bridgehub.l2TransactionBaseCost(
            _chainId,
            DEPOSIT_GAS_PRICE,
            CAP_L2_GAS_LIMIT + 1,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        vm.deal(depositor, mint);
        vm.txGasPrice(DEPOSIT_GAS_PRICE);
        request = L2TransactionRequestDirect({
            chainId: _chainId,
            mintValue: mint,
            l2Contract: depositor,
            l2Value: 0,
            l2Calldata: "",
            l2GasLimit: _l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: new bytes[](0),
            refundRecipient: depositor
        });
    }

    /// @dev A deposit the chain accepts: one more priority transaction, announced with its id.
    function _deposit(uint256 _chainId, uint256 _l2GasLimit) internal {
        IZKChain chain = _chain(_chainId);
        (address depositor, uint256 mint, L2TransactionRequestDirect memory request) = _depositRequest(
            _chainId,
            _l2GasLimit
        );
        uint256 count = chain.getTotalPriorityTxs();
        vm.expectEmit(true, false, false, false, address(chain));
        emit IMailboxImpl.NewPriorityRequestId(count, bytes32(0));
        vm.prank(depositor, depositor);
        bridgehub.requestL2TransactionDirect{value: mint}(request);
        assertEq(chain.getTotalPriorityTxs(), count + 1, "one more priority transaction");
    }

    function _switchAirbender(
        IZKChain _zkChain,
        IServerNotifier _serverNotifier,
        address _admin,
        bool _enable
    ) internal {
        DisabledProofSystems memory next = DisabledProofSystems({boojum: false, airbender: !_enable});
        uint256 chainId = _zkChain.getChainId();
        vm.expectEmit(true, false, false, true, address(_serverNotifier));
        emit IServerNotifier.ProofSystemStatusNotified(chainId, next);
        vm.prank(_admin);
        _serverNotifier.notifyProofSystemStatus(chainId, next);

        uint8 disabledBefore = _enable ? AIRBENDER_PROOF_SYSTEM_MASK : 0;
        uint8 disabledAfter = _enable ? 0 : AIRBENDER_PROOF_SYSTEM_MASK;
        vm.expectEmit(true, true, false, true, address(_zkChain));
        emit IAdmin.NewDisabledProofSystems(disabledBefore, disabledAfter);
        vm.prank(_admin);
        _zkChain.setProofSystemStatus(ProofSystem.Airbender, _enable);
    }
}
