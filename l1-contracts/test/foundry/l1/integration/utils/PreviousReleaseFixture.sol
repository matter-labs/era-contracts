// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {
    EMPTY_STRING_KECCAK,
    GENESIS_BATCH_COMMITMENT,
    L2DACommitmentScheme,
    PUBLIC_INPUT_SHIFT,
    TESTNET_COMMIT_TIMESTAMP_NOT_OLDER,
    ZKSYNC_OS_MOCK_PROOF_MAGIC,
    ZKSYNC_OS_MOCK_VERIFICATION_TYPE
} from "contracts/common/Config.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS, ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {
    ANVIL_FIXTURE_DEPLOYER,
    ANVIL_FIXTURE_L1_CHAIN_ID,
    BATCH_COMMIT_ENCODING_V5,
    BATCH_COMMIT_ENCODING_V6_FIRST_MINOR
} from "../../../TestConstants.sol";

/// @notice `CommitBatchInfoZKsyncOS` as commit encoding 5 (releases before v0.35) has it: without the trailing
///         `interopFeeUnits`.
struct CommitBatchInfoZKsyncOSV5 {
    uint64 batchNumber;
    bytes32 newStateCommitment;
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;
    L2DACommitmentScheme daCommitmentScheme;
    bytes32 daCommitment;
    uint64 firstBlockTimestamp;
    uint64 firstBlockNumber;
    uint64 lastBlockTimestamp;
    uint64 lastBlockNumber;
    uint256 chainId;
    bytes operatorDAInput;
    uint256 slChainId;
    bytes32 chainConfigHash;
}

/// @notice The previous release's ecosystem, loaded from the frozen anvil-interop chain states the release
///         rotation keeps (`upgradeSourceStateVersion` in `test/anvil-interop/config/anvil-config.json`), so an
///         upgrade test departs from what that release really deployed rather than from the current sources.
/// @dev Only the L1 state is loaded: the L2 leg stays with the anvil upgrade test.
abstract contract PreviousReleaseFixture is Test {
    using stdJson for string;

    struct PreviousRelease {
        string stateVersion;
        address bridgehub;
        address sharedBridge;
        address nativeTokenVault;
        address nullifier;
        address governance;
        address chainTypeManager;
        address ctmChainAdmin;
    }

    struct FixtureChain {
        uint256 chainId;
        address diamondProxy;
        IExecutor.StoredBatchInfo lastBatch;
    }

    string internal constant ANVIL_INTEROP_DIR = "/test/anvil-interop";

    /// @notice Loads the previous release's L1 state into this test's EVM.
    function _loadPreviousRelease() internal returns (PreviousRelease memory release) {
        string memory root = vm.projectRoot();
        string memory anvilConfig = vm.readFile(string.concat(root, ANVIL_INTEROP_DIR, "/config/anvil-config.json"));
        release.stateVersion = anvilConfig.readString(".upgradeSourceStateVersion");

        string[] memory convert = new string[](4);
        convert[0] = "node";
        convert[1] = "scripts/chain-state-allocs.js";
        convert[2] = release.stateVersion;
        convert[3] = vm.toString(ANVIL_FIXTURE_L1_CHAIN_ID);
        (uint256 blockNumber, uint256 blockTimestamp) = abi.decode(vm.ffi(convert), (uint256, uint256));
        string memory allocsName = string.concat(convert[2], "-", convert[3], ".json");
        vm.loadAllocs(string.concat(root, ANVIL_INTEROP_DIR, "/outputs/allocs/", allocsName));
        vm.chainId(ANVIL_FIXTURE_L1_CHAIN_ID);
        vm.roll(blockNumber);
        // The dump's clock sits minutes after 1970, and commit rejects batches older than this window
        // (`block.timestamp - TESTNET_COMMIT_TIMESTAMP_NOT_OLDER` underflows below it).
        vm.warp(blockTimestamp + TESTNET_COMMIT_TIMESTAMP_NOT_OLDER);

        string memory addresses = vm.readFile(
            string.concat(root, ANVIL_INTEROP_DIR, "/chain-states/", release.stateVersion, "/addresses.json")
        );
        release.bridgehub = addresses.readAddress(".l1Addresses.bridgehub");
        release.sharedBridge = addresses.readAddress(".l1Addresses.l1SharedBridge");
        release.nativeTokenVault = addresses.readAddress(".l1Addresses.l1NativeTokenVault");
        release.nullifier = addresses.readAddress(".l1Addresses.l1NullifierProxy");
        release.governance = addresses.readAddress(".l1Addresses.governance");
        release.chainTypeManager = addresses.readAddress(".ctmAddresses.chainTypeManager");
        release.ctmChainAdmin = addresses.readAddress(".ctmAddresses.chainAdmin");
    }

    /// @notice Gives the loaded ecosystem a production ecosystem's authority, which the anvil fixtures partly leave
    ///         with their deployer: governance owns the core contracts, the CTM and the CTM's ProxyAdmin, and the CTM's
    ///         ChainAdmin owns the ServerNotifier.
    function _handAuthorityToGovernance(PreviousRelease memory _release) internal {
        _transferTwoStep(_release.bridgehub, _release.governance);
        _transferTwoStep(_release.sharedBridge, _release.governance);
        _transferTwoStep(_release.nativeTokenVault, _release.governance);
        _transferTwoStep(_release.nullifier, _release.governance);
        _transferTwoStep(_release.chainTypeManager, _release.governance);

        ProxyAdmin ctmProxyAdmin = ProxyAdmin(Utils.getProxyAdminAddress(_release.chainTypeManager));
        vm.prank(ctmProxyAdmin.owner());
        ctmProxyAdmin.transferOwnership(_release.governance);

        address notifier = IChainTypeManager(_release.chainTypeManager).serverNotifierAddress();
        vm.prank(IOwnable(notifier).owner());
        IOwnable(notifier).transferOwnership(_release.ctmChainAdmin);
        IChainAdminOwnable.Call[] memory accept = new IChainAdminOwnable.Call[](1);
        accept[0] = IChainAdminOwnable.Call({target: notifier, value: 0, data: abi.encodeCall(IOwnable.acceptOwnership, ())});
        vm.prank(IOwnable(_release.ctmChainAdmin).owner());
        IChainAdminOwnable(_release.ctmChainAdmin).multicall(accept, true);
    }

    /// @notice Hands `_chain` to a new `ChainAdminOwnable` owned by the fixture's deployer, as production chains are
    ///         administered through a ChainAdmin rather than an EOA.
    function _installChainAdmin(FixtureChain memory _chain) internal returns (address chainAdmin) {
        chainAdmin = address(new ChainAdminOwnable(ANVIL_FIXTURE_DEPLOYER, ANVIL_FIXTURE_DEPLOYER));
        vm.prank(IGetters(_chain.diamondProxy).getAdmin());
        IAdmin(_chain.diamondProxy).setPendingAdmin(chainAdmin);
        IChainAdminOwnable.Call[] memory accept = new IChainAdminOwnable.Call[](1);
        accept[0] = IChainAdminOwnable.Call({target: _chain.diamondProxy, value: 0, data: abi.encodeCall(IAdmin.acceptAdmin, ())});
        vm.prank(ANVIL_FIXTURE_DEPLOYER);
        IChainAdminOwnable(chainAdmin).multicall(accept, true);
    }

    /// @notice The fixture chain `_chainId`, positioned at batch zero for {_settleBatch}.
    /// @param _genesisBatchHash The genesis root of the release the chain was created from. Batch zero is rebuilt
    ///        from it and checked against the chain's stored hash, since a pre-registry CTM keeps only that hash.
    function _fixtureChain(
        uint256 _chainId,
        bytes32 _genesisBatchHash
    ) internal view returns (FixtureChain memory chain) {
        string memory addresses = vm.readFile(
            string.concat(
                vm.projectRoot(),
                ANVIL_INTEROP_DIR,
                "/chain-states/",
                _previousStateVersion(),
                "/addresses.json"
            )
        );
        for (uint256 i = 0; addresses.keyExists(string.concat(".chainAddresses[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat(".chainAddresses[", vm.toString(i), "]");
            if (addresses.readUint(string.concat(entry, ".chainId")) == _chainId) {
                chain.chainId = _chainId;
                chain.diamondProxy = addresses.readAddress(string.concat(entry, ".diamondProxy"));
            }
        }
        require(chain.diamondProxy != address(0), "chain not in the fixture");
        require(IGetters(chain.diamondProxy).getTotalBatchesCommitted() == 0, "fixture chain already committed");

        chain.lastBatch = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: _genesisBatchHash,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: bytes32(0),
            timestamp: 0,
            commitment: GENESIS_BATCH_COMMITMENT
        });
        require(
            keccak256(abi.encode(chain.lastBatch)) == IGetters(chain.diamondProxy).storedBatchHash(0),
            "batch zero does not match the chain's stored genesis batch"
        );
    }

    /// @notice Gives `_chain` the Validium DA pair commit requires, which the fixture chains lack. Sent as the
    ///         chain's admin, so it runs before the admin is handed over.
    function _prepareSettlement(FixtureChain memory _chain) internal {
        ValidiumL1DAValidator daValidator = new ValidiumL1DAValidator();
        vm.prank(IGetters(_chain.diamondProxy).getAdmin());
        IAdmin(_chain.diamondProxy).setDAValidatorPair(address(daValidator), L2DACommitmentScheme.EMPTY_NO_DA);
    }

    /// @notice Commits, proves and executes one empty batch on `_chain` through its CTM's ValidatorTimelock, as the
    ///         fixture's operator, so its L1 state is what settling reaches: a pending system upgrade tx goes into
    ///         the batch, and every committed batch is executed. Proven with the mock proof the testnet verifier
    ///         accepts.
    function _settleBatch(FixtureChain memory _chain) internal {
        IGetters getters = IGetters(_chain.diamondProxy);
        IValidatorTimelock timelock = IValidatorTimelock(
            IChainTypeManager(getters.getChainTypeManager()).validatorTimelockPostV29()
        );
        IExecutor.StoredBatchInfo memory prevBatch = _chain.lastBatch;
        uint64 batchNumber = prevBatch.batchNumber + 1;
        // A batch without L2->L1 logs or interop has the genesis chain batch root; MessageRoot rejects a zero one.
        bytes32 emptyBatchRoot = getters.l2LogsRootHash(0);

        (, uint32 minor, ) = getters.getSemverProtocolVersion();
        bytes memory commitData = _encodeCommit(_chain, prevBatch, batchNumber, emptyBatchRoot, minor);

        vm.recordLogs();
        vm.prank(ANVIL_FIXTURE_DEPLOYER);
        timelock.commitBatchesSharedBridge(_chain.diamondProxy, batchNumber, batchNumber, commitData);
        IExecutor.StoredBatchInfo memory storedBatch = IExecutor.StoredBatchInfo({
            batchNumber: batchNumber,
            batchHash: prevBatch.batchHash,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: emptyBatchRoot,
            timestamp: 0,
            commitment: _committedCommitment(_chain.diamondProxy)
        });
        assertEq(keccak256(abi.encode(storedBatch)), getters.storedBatchHash(batchNumber), "rebuilt batch mismatch");

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = storedBatch;
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;
        proof[2] = ZKSYNC_OS_MOCK_PROOF_MAGIC;
        proof[3] = uint256(storedBatch.commitment) >> PUBLIC_INPUT_SHIFT;
        vm.prank(ANVIL_FIXTURE_DEPLOYER);
        timelock.proveBatchesSharedBridge(
            _chain.diamondProxy,
            batchNumber,
            batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION), abi.encode(prevBatch, batches, proof))
        );

        BatchDecoder.DecodedExecuteData memory executeData;
        executeData.batchesData = batches;
        executeData.priorityOpsData = new PriorityOpsBatchInfo[](1);
        executeData.dependencyRoots = new InteropRoot[][](1);
        vm.prank(ANVIL_FIXTURE_DEPLOYER);
        timelock.executeBatchesSharedBridge(
            _chain.diamondProxy,
            batchNumber,
            batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE), abi.encode(executeData))
        );

        assertEq(getters.getTotalBatchesExecuted(), batchNumber, "batch not executed");
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), bytes32(0), "system upgrade tx still pending");
        _chain.lastBatch = storedBatch;
    }

    function _encodeCommit(
        FixtureChain memory _chain,
        IExecutor.StoredBatchInfo memory _prevBatch,
        uint64 _batchNumber,
        bytes32 _emptyBatchRoot,
        uint32 _minor
    ) private view returns (bytes memory) {
        IGetters getters = IGetters(_chain.diamondProxy);
        CommitBatchInfoZKsyncOSV5[] memory commits = new CommitBatchInfoZKsyncOSV5[](1);
        commits[0] = CommitBatchInfoZKsyncOSV5({
            batchNumber: _batchNumber,
            newStateCommitment: _prevBatch.batchHash,
            numberOfLayer1Txs: 0,
            numberOfLayer2Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: _emptyBatchRoot,
            daCommitmentScheme: L2DACommitmentScheme.EMPTY_NO_DA,
            daCommitment: bytes32(0),
            firstBlockTimestamp: uint64(block.timestamp),
            firstBlockNumber: _batchNumber,
            lastBlockTimestamp: uint64(block.timestamp),
            lastBlockNumber: _batchNumber,
            chainId: _chain.chainId,
            // ValidiumL1DAValidator takes the batch's state diff hash, which it does not check.
            operatorDAInput: abi.encode(bytes32(0)),
            slChainId: block.chainid,
            chainConfigHash: getters.getZKsyncOSChainConfigHash()
        });
        if (_minor < BATCH_COMMIT_ENCODING_V6_FIRST_MINOR) {
            return bytes.concat(bytes1(BATCH_COMMIT_ENCODING_V5), abi.encode(_prevBatch, commits));
        }
        CommitBatchInfoZKsyncOS[] memory current = new CommitBatchInfoZKsyncOS[](1);
        CommitBatchInfoZKsyncOSV5 memory c = commits[0];
        current[0] = CommitBatchInfoZKsyncOS({
            batchNumber: c.batchNumber,
            newStateCommitment: c.newStateCommitment,
            numberOfLayer1Txs: c.numberOfLayer1Txs,
            numberOfLayer2Txs: c.numberOfLayer2Txs,
            priorityOperationsHash: c.priorityOperationsHash,
            dependencyRootsRollingHash: c.dependencyRootsRollingHash,
            l2LogsTreeRoot: c.l2LogsTreeRoot,
            daCommitmentScheme: c.daCommitmentScheme,
            daCommitment: c.daCommitment,
            firstBlockTimestamp: c.firstBlockTimestamp,
            firstBlockNumber: c.firstBlockNumber,
            lastBlockTimestamp: c.lastBlockTimestamp,
            lastBlockNumber: c.lastBlockNumber,
            chainId: c.chainId,
            operatorDAInput: c.operatorDAInput,
            slChainId: c.slChainId,
            chainConfigHash: c.chainConfigHash,
            interopFeeUnits: 0
        });
        return bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT), abi.encode(_prevBatch, current));
    }

    function _committedCommitment(address _diamondProxy) private returns (bytes32 commitment) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == _diamondProxy && logs[i].topics[0] == ICommitter.BlockCommit.selector) {
                commitment = logs[i].topics[3];
                ++found;
            }
        }
        assertEq(found, 1, "expected one BlockCommit");
    }

    function _transferTwoStep(address _target, address _newOwner) private {
        address owner = IOwnable(_target).owner();
        if (owner == _newOwner) {
            return;
        }
        vm.prank(owner);
        IOwnable(_target).transferOwnership(_newOwner);
        vm.prank(_newOwner);
        IOwnable(_target).acceptOwnership();
    }

    function _previousStateVersion() private view returns (string memory) {
        string memory anvilConfig = vm.readFile(
            string.concat(vm.projectRoot(), ANVIL_INTEROP_DIR, "/config/anvil-config.json")
        );
        return anvilConfig.readString(".upgradeSourceStateVersion");
    }
}
