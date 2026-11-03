// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "deploy-scripts/utils/Utils.sol";

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
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IServerNotifier} from "contracts/governance/IServerNotifier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

/// @title V34EraUpgradeForkTest
/// @notice v34 Era checks on protocol-ops' replayed fork (`fork_tests`).
/// @dev The L1 before the upgrade is read on a fork of `FORK_URL` at `FORK_BLOCK`: concurrent reads below the
/// replayed fork's head deadlock its Anvil (see protocol-ops' `run_fork_tests`).
contract V34EraUpgradeForkTest is Test {
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

    /// @dev The v34 genesis values the checks compare with.
    struct Genesis {
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        bytes32 root;
        uint64 leafIndex;
        bytes32 batchCommitment;
        bytes32 airbenderBatchCommitment;
    }

    string internal forkUrl;
    uint256 internal forkBlock;
    uint256 internal referenceChainId;
    uint256 internal testChainId;
    string internal checksDir;
    string internal envTomlPath;
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
        // The script's CTM: the first one, which must be Era.
        string memory permanent = vm.readFile(
            string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/", env, ".toml")
        );
        assertFalse(vm.parseTomlBool(permanent, "$.ctm_contracts.ctms[0].is_zk_sync_os"), "the first CTM is Era");
        bridgehub = IL1Bridgehub(vm.parseTomlAddress(permanent, "$.core_contracts.bridgehub_proxy_addr"));
        ctm = IChainTypeManager(vm.parseTomlAddress(permanent, "$.ctm_contracts.ctms[0].proxy"));
        replayedFork = vm.activeFork();
    }

    // ─── The CTM and the ServerNotifier ──────────────────────────────────────────────

    function test_ctmAndServerNotifierAfterTheStages() public {
        string memory out = _output();
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

        EraMultiProofVerifier verifier = EraMultiProofVerifier(ctm.protocolVersionVerifier(_newProtocolVersion(out)));
        assertEq(
            verifier.IS_TESTNET_VERIFIER(),
            vm.parseTomlBool(vm.readFile(envTomlPath), "$.testnet_verifier"),
            "verifier: testnet flag = the env's testnet_verifier"
        );
        assertEq(
            address(verifier.BOOJUM_VERIFIER()),
            _outputAddress(out, "verifier_fflonk_addr"),
            "verifier: Boojum verifier"
        );
        assertEq(
            address(verifier.AIRBENDER_VERIFIER()),
            _outputAddress(out, "airbender_verifier_addr"),
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
        assertEq(ctm.l1GenesisUpgrade(), _outputAddress(out, "genesis_upgrade_addr"), "CTM l1GenesisUpgrade");
        assertEq(ctm.storedBatchZero(), keccak256(abi.encode(_batchZero(_genesis(genesis)))), "CTM storedBatchZero");

        address ctmImplementation = _outputAddress(out, "chain_type_manager_implementation_addr");
        address serverNotifierImplementation = _outputAddress(out, "server_notifier_implementation_addr");
        address[4] memory owned = [
            address(ctm),
            ctmImplementation,
            address(serverNotifier),
            serverNotifierImplementation
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
        IChainTypeManager(ctmImplementation).initialize(init);
        // A proxy initialized before `initialize` took `initializer` (mainnet's) has `_initialized` 0: only the
        // reentrancy guard stops a second call. The implementation's disabled initializers pin the slot and offset.
        assertEq(
            _serverNotifierInitialized(serverNotifierImplementation),
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
        ServerNotifier(serverNotifierImplementation).initialize(address(this));
    }

    // ─── The chains ──────────────────────────────────────────────────────────────────

    function test_upgradedChainsState() public {
        string memory out = _output();
        Diamond.DiamondCutData memory cut = abi.decode(
            vm.parseTomlBytes(out, "$.chain_upgrade_diamond_cut"),
            (Diamond.DiamondCutData)
        );
        Genesis memory genesis = _genesis(vm.readFile(Utils.genesisConfigPath(false)));
        _checkChainState(referenceChainId, out, cut, genesis);
        _checkChainState(testChainId, out, cut, genesis);
        IZKChain chain = _chain(referenceChainId);
        assertEq(
            chain.getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(_proposedUpgrade(cut).l2ProtocolUpgradeTx)),
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

    /// @dev The output protocol-ops replayed.
    function _output() internal view returns (string memory) {
        return vm.readFile(string.concat(checksDir, "/ecosystem.toml"));
    }

    function _outputAddress(string memory _toml, string memory _key) internal pure returns (address) {
        return vm.parseTomlAddress(_toml, string.concat("$.state_transition.", _key));
    }

    function _newProtocolVersion(string memory _toml) internal pure returns (uint256) {
        return vm.parseTomlUint(_toml, "$.contracts_config.new_protocol_version");
    }

    function _proposedUpgrade(Diamond.DiamondCutData memory _cut) internal pure returns (ProposedUpgrade memory) {
        assertEq(bytes4(_cut.initCalldata), IDefaultUpgrade.upgrade.selector, "the cut calls upgrade(ProposedUpgrade)");
        return abi.decode(Bytes.slice(_cut.initCalldata, 4), (ProposedUpgrade));
    }

    /// @dev The cut's facet cuts after its leading Removes.
    function _adds(Diamond.DiamondCutData memory _cut) internal pure returns (Diamond.FacetCut[] memory added) {
        uint256 removes = 0;
        while (removes < _cut.facetCuts.length && _cut.facetCuts[removes].action == Diamond.Action.Remove) {
            ++removes;
        }
        added = new Diamond.FacetCut[](_cut.facetCuts.length - removes);
        for (uint256 i = 0; i < added.length; ++i) {
            added[i] = _cut.facetCuts[removes + i];
        }
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

    function _genesis(string memory _json) internal pure returns (Genesis memory) {
        return
            Genesis({
                bootloaderHash: vm.parseJsonBytes32(_json, "$.bootloader_hash"),
                defaultAccountHash: vm.parseJsonBytes32(_json, "$.default_aa_hash"),
                evmEmulatorHash: vm.parseJsonBytes32(_json, "$.evm_emulator_hash"),
                root: vm.parseJsonBytes32(_json, "$.genesis_root"),
                leafIndex: uint64(vm.parseJsonUint(_json, "$.genesis_rollup_leaf_index")),
                batchCommitment: vm.parseJsonBytes32(_json, "$.genesis_batch_commitment"),
                airbenderBatchCommitment: vm.parseJsonBytes32(_json, "$.genesis_airbender_batch_commitment")
            });
    }

    /// @dev As `ChainTypeManagerBase` stores it for the new chain creation params.
    function _batchZero(Genesis memory _genesisValues) internal pure returns (IExecutor.StoredBatchInfo memory) {
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
        string memory _out,
        Diamond.DiamondCutData memory _cut,
        Genesis memory _genesisValues
    ) internal view {
        IZKChain chain = _chain(_chainId);
        string memory label = string.concat("chain ", vm.toString(_chainId), ": ");
        assertEq(chain.getProtocolVersion(), _newProtocolVersion(_out), string.concat(label, "protocol version"));
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
        assertEq(chain.getVerifier(), _outputAddress(_out, "verifier_addr"), string.concat(label, "verifier"));
        DisabledProofSystems memory disabled = chain.disabledProofSystems();
        assertTrue(!disabled.boojum && !disabled.airbender, string.concat(label, "no proof system disabled"));
        assertEq(
            chain.getUserPriorityTxMaxGasLimit(),
            USER_PRIORITY_TX_MAX_GAS_LIMIT,
            string.concat(label, "user priority tx gas cap")
        );
        // The cut's Adds exactly: each facet routes its selectors with its freezable flag.
        Diamond.FacetCut[] memory adds = _adds(_cut);
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
