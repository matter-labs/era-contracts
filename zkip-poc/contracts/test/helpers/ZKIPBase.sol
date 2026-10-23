// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {ZKIPLiteRegistry, IHonkVerifier} from "../../src/ZKIPLiteRegistry.sol";
import {MockCaps} from "../../src/mocks/MockCaps.sol";
import {MockMessageRoot} from "../../src/mocks/MockMessageRoot.sol";
import {ChainSim} from "../../src/mocks/ChainSim.sol";
import {LegBuilder} from "./LegBuilder.sol";
import {ImtInsertion} from "../../src/ImtInsertion.sol";
import {ZERO_BYTE_GAS, NONZERO_BYTE_GAS} from "./ZKIPTestConfig.sol";

/// @notice Shared setup and helpers of the ZKIP-lite end-to-end tests. Every proof is produced during the test by
/// ../prover/prove.py (vm.ffi: nargo + bb) from the same data the L1 contracts see, and verified on chain by bb's
/// generated Solidity verifiers. Run with --threads 1: proving is CPU-bound and the prover writes per-test files under
/// ../work/e2e.
abstract contract ZKIPBase is Test {
    uint256 internal constant A = 270_270;
    uint256 internal constant B = 270_271;
    uint256 internal constant C = 270_272; // registered for interop, not a ZKIP chain
    string internal constant WORK = "../work/e2e/";
    string internal constant EVM = "evm";
    string internal constant REC = "rec";
    uint8 internal constant SLOT_DEBIT = 1;
    uint8 internal constant SLOT_CLAIM = 2;

    struct Swap {
        bytes bundleA;
        bytes bundleB;
        bytes pre;
        uint256 legOfA;
        uint256 cvA;
        uint256 cvB;
    }

    struct Credit {
        bytes bundle;
        bytes pre;
        uint256 creditLeg;
        uint256[2] legCvs;
        ChainSim[2] legChains;
    }

    /// @notice The public data a debit proof is built from (the prover adds the chain's private state).
    struct DebitWitness {
        uint256 chainId;
        bytes[] bundles;
        bytes[] preimages;
        uint256[] legs;
        bytes32 lockAsset;
        uint256 lockAmount;
    }

    /// @notice The public data a claim proof is built from.
    struct ClaimWitness {
        uint256 chainId;
        Credit[] credits;
        bytes32 unlockAsset;
        uint256 unlockAmount;
    }

    /// @notice A statement a chain proved for the aggregator (noir-recursive proof in `dir`) and its L1 data.
    struct Inner {
        uint8 kind;
        string circuit;
        string dir;
        uint256 chainId;
        string stateOut;
        ZKIPLiteRegistry.DebitSubmission debit;
        ZKIPLiteRegistry.ClaimSubmission claim;
    }

    MockMessageRoot internal mroot;
    MockCaps internal caps;
    ZKIPLiteRegistry internal reg;
    ChainSim internal simA;
    ChainSim internal simB;
    ChainSim internal simC;
    LegBuilder.Token internal usdc;
    LegBuilder.Token internal eurc;
    bytes32 internal usdcId;
    bytes32 internal eurcId;
    uint256 internal lastPushBlock;
    bytes32[4] internal aggVkCommitments; // debit_1, debit_4, claim_1, claim_2
    mapping(uint256 chainId => string path) internal stateFile;
    mapping(uint256 chainId => string path) internal pendingState;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.createDir(WORK, true);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        mroot = new MockMessageRoot();
        caps = new MockCaps();
        reg = new ZKIPLiteRegistry(mroot, caps);
        caps.setRegistry(address(reg));

        uint256[] memory debitSizes = new uint256[](2);
        debitSizes[0] = 1;
        debitSizes[1] = 4;
        IHonkVerifier[] memory debitVerifiers = new IHonkVerifier[](2);
        debitVerifiers[0] = IHonkVerifier(deployCode("Debit1Verifier.sol:HonkVerifier"));
        debitVerifiers[1] = IHonkVerifier(deployCode("Debit4Verifier.sol:HonkVerifier"));
        uint256[] memory claimSizes = new uint256[](2);
        claimSizes[0] = 1;
        claimSizes[1] = 2;
        IHonkVerifier[] memory claimVerifiers = new IHonkVerifier[](2);
        claimVerifiers[0] = IHonkVerifier(deployCode("Claim1Verifier.sol:HonkVerifier"));
        claimVerifiers[1] = IHonkVerifier(deployCode("Claim2Verifier.sol:HonkVerifier"));
        reg.setVerifiers(debitSizes, debitVerifiers, claimSizes, claimVerifiers);
        _approveAggregation(true);

        simA = new ChainSim(A, reg, mroot);
        simB = new ChainSim(B, reg, mroot);
        simC = new ChainSim(C, reg, mroot);
        mroot.addChain(A, address(simA));
        mroot.addChain(B, address(simB));
        mroot.addChain(C, address(simC));
        for (uint256 i = 0; i < 4; ++i) {
            mroot.addChain(300_000 + i, address(0)); // other L1-settled chains: the shared tree gets height 3
        }

        bytes32 emptyState = bytes32(vm.ffi(_prover("init-root")));
        reg.enableChain(A, address(simA), emptyState);
        reg.enableChain(B, address(simB), emptyState);
        stateFile[A] = "-";
        stateFile[B] = "-";

        usdc = LegBuilder.Token(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, block.chainid, "USD Coin", "USDC", 6);
        eurc = LegBuilder.Token(0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c, block.chainid, "EURC", "EURC", 6);
        usdcId = LegBuilder.assetId(usdc);
        eurcId = LegBuilder.assetId(eurc);
        caps.deposit(A, usdcId, 100e6);
        caps.deposit(B, eurcId, 50e6);
    }

    /// @dev Registers (or revokes) the agg_4 verifier and the VK commitments of the circuits it may carry.
    function _approveAggregation(bool _approve) internal {
        if (aggVkCommitments[0] == bytes32(0)) {
            (aggVkCommitments[0], aggVkCommitments[1], aggVkCommitments[2], aggVkCommitments[3]) = abi.decode(
                vm.ffi(_prover("vk-commits")),
                (bytes32, bytes32, bytes32, bytes32)
            );
        }
        bytes32[] memory commitments = new bytes32[](4);
        uint256[] memory circuits = new uint256[](4);
        for (uint256 i = 0; i < 4; ++i) {
            commitments[i] = aggVkCommitments[i];
        }
        if (_approve) {
            (circuits[0], circuits[1], circuits[2], circuits[3]) = (
                reg.CIRCUIT_DEBIT_1(),
                reg.CIRCUIT_DEBIT_4(),
                reg.CIRCUIT_CLAIM_1(),
                reg.CIRCUIT_CLAIM_2()
            );
        }
        IHonkVerifier aggVerifier = address(reg.aggVerifier()) == address(0)
            ? IHonkVerifier(deployCode("Agg4Verifier.sol:HonkVerifier"))
            : reg.aggVerifier();
        reg.setAggregation(aggVerifier, commitments, circuits);
    }

    // ------------------------------------------------------------------------------------ flows

    function _swap(
        uint256 _from,
        uint256 _to,
        uint256 _amountA,
        uint256 _amountB,
        uint64 _deadline,
        bytes32 _salt
    ) internal view returns (Swap memory s) {
        s.bundleA = LegBuilder.bundle(LegBuilder.Leg(_from, _to, usdc, _amountA, alice, bob, _salt));
        s.bundleB = LegBuilder.bundle(LegBuilder.Leg(_to, _from, eurc, _amountB, bob, alice, _salt));
        (s.pre, s.legOfA) = LegBuilder.flow(s.bundleA, _from, s.bundleB, _to, _deadline, block.chainid);
        s.cvA = LegBuilder.commitValue(s.pre, s.bundleA);
        s.cvB = LegBuilder.commitValue(s.pre, s.bundleB);
    }

    function _slotCvs(Swap memory _s) internal pure returns (uint256[2] memory cvs) {
        cvs[_s.legOfA] = _s.cvA;
        cvs[1 - _s.legOfA] = _s.cvB;
    }

    function _slotChains(Swap memory _s, ChainSim _a, ChainSim _b) internal pure returns (ChainSim[2] memory sims) {
        sims[_s.legOfA] = _a;
        sims[1 - _s.legOfA] = _b;
    }

    function _credits(Swap memory _s, bytes memory _bundle, uint256 _leg) internal view returns (Credit[] memory c) {
        c = new Credit[](1);
        c[0] = Credit(_bundle, _s.pre, _leg, _slotCvs(_s), _slotChains(_s, simA, simB));
    }

    function _commitLegs(ChainSim _sim, uint256[] memory _cvs) internal {
        _sim.beginBatch();
        for (uint256 i = 0; i < _cvs.length; ++i) {
            _sim.commitLeg(_cvs[i]);
        }
        _sim.endBatch(keccak256(abi.encode("logs", _sim.chainId(), _sim.lastCommitted())));
    }

    function _execute(ChainSim _sim, uint256 _batch) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _sim.execute(_batch);
        lastPushBlock = block.number;
    }

    function _chainState(
        uint256 _chainId
    ) internal view returns (bytes32 stateRoot, bytes32 provenImtRoot, uint256 leafCount, bytes32 executedImtRoot) {
        (, stateRoot, provenImtRoot, leafCount, executedImtRoot) = reg.chains(_chainId);
    }

    // ---------------------------------------------------------------------------- direct path

    function _submission(
        ChainSim _sim,
        uint256 _batch,
        bytes32 _lockAsset,
        uint256 _lockAmount,
        bytes32 _newRoot,
        bytes memory _proof
    ) internal view returns (ZKIPLiteRegistry.DebitSubmission memory sub) {
        sub.chainId = _sim.chainId();
        sub.batchNumber = _batch;
        sub.cbr = _sim.preimage(_batch);
        sub.numLegs = _sim.legsOf(_batch).length;
        sub.lockAssetId = _lockAsset;
        sub.lockAmount = _lockAmount;
        sub.newStateRoot = _newRoot;
        sub.proof = _proof;
    }

    function _claimSubmission(
        uint256 _chainId,
        uint256 _numCredits,
        bytes32 _unlockAsset,
        uint256 _unlockAmount,
        bytes32 _newRoot,
        bytes memory _proof
    ) internal view returns (ZKIPLiteRegistry.ClaimSubmission memory sub) {
        sub.chainId = _chainId;
        sub.numCredits = _numCredits;
        sub.anchorBlocks = [lastPushBlock, lastPushBlock];
        sub.unlockAssetId = _unlockAsset;
        sub.unlockAmount = _unlockAmount;
        sub.newStateRoot = _newRoot;
        sub.proof = _proof;
    }

    function _debitAndSubmit(
        ChainSim _sim,
        uint256 _batch,
        bytes[] memory _bundles,
        bytes[] memory _preimages,
        uint256[] memory _legs,
        bytes32 _lockAsset,
        uint256 _lockAmount,
        string memory _tag
    ) internal {
        uint256 chainId = _sim.chainId();
        (bool ok, bytes32 newRoot, bytes memory proof) = _proveDebit(
            chainId,
            _bundles,
            _preimages,
            _legs,
            _lockAsset,
            _lockAmount,
            _tag
        );
        assertTrue(ok, string.concat("prover failed: ", _tag));
        ZKIPLiteRegistry.DebitSubmission memory sub = _submission(
            _sim,
            _batch,
            _lockAsset,
            _lockAmount,
            newRoot,
            proof
        );
        (, , uint256 beforeCount, ) = _chainState(chainId);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.DebitProven(chainId, _batch, sub.numLegs, newRoot);
        uint256 g = gasleft();
        reg.submitDebit(sub);
        _logGas(string.concat(_tag, ": submitDebit"), g - gasleft(), abi.encodeCall(reg.submitDebit, (sub)));
        stateFile[chainId] = pendingState[chainId];
        (bytes32 stored, bytes32 provenImt, uint256 afterCount, ) = _chainState(chainId);
        assertEq(stored, newRoot);
        assertEq(provenImt, sub.cbr.imtEnd);
        assertEq(afterCount, beforeCount + sub.numLegs);
    }

    function _claimAndSubmit(
        uint256 _chainId,
        Credit[] memory _creditList,
        bytes32 _unlockAsset,
        uint256 _unlockAmount,
        string memory _tag
    ) internal {
        (bool ok, bytes32 newRoot, bytes memory proof) = _proveClaim(
            _chainId,
            _creditList,
            _unlockAsset,
            _unlockAmount,
            _tag
        );
        assertTrue(ok, string.concat("prover failed: ", _tag));
        ZKIPLiteRegistry.ClaimSubmission memory sub = _claimSubmission(
            _chainId,
            _creditList.length,
            _unlockAsset,
            _unlockAmount,
            newRoot,
            proof
        );
        uint256 g = gasleft();
        reg.submitClaim(sub);
        _logGas(string.concat(_tag, ": submitClaim"), g - gasleft(), abi.encodeCall(reg.submitClaim, (sub)));
        stateFile[_chainId] = pendingState[_chainId];
    }

    function _proveDebit(
        uint256 _chainId,
        bytes[] memory _bundles,
        bytes[] memory _preimages,
        uint256[] memory _legs,
        bytes32 _lockAsset,
        uint256 _lockAmount,
        string memory _tag
    ) internal returns (bool, bytes32, bytes memory) {
        DebitWitness memory w = DebitWitness(_chainId, _bundles, _preimages, _legs, _lockAsset, _lockAmount);
        return _proveDebitWith(w, _tag, _bundles.length <= 1 ? 1 : 4, EVM);
    }

    function _proveDebitWith(
        DebitWitness memory _w,
        string memory _tag,
        uint256 _size,
        string memory _target
    ) internal returns (bool, bytes32, bytes memory) {
        vm.serializeUint(_tag, "chain_id", _w.chainId);
        vm.serializeUint(_tag, "l1_chain_id", block.chainid);
        vm.serializeUint(_tag, "num_legs", _w.bundles.length);
        vm.serializeBytes(_tag, "bundles", _w.bundles);
        vm.serializeBytes(_tag, "preimages", _w.preimages);
        vm.serializeUint(_tag, "leg_index", _w.legs);
        vm.serializeBytes32(_tag, "lock_asset", _w.lockAsset);
        vm.serializeUint(_tag, "lock_amount", _w.lockAmount);
        string memory json = _serializeDebitImt(_w, _tag);
        return _runProver("debit", _size, json, _w.chainId, _tag, _target);
    }

    function _serializeDebitImt(DebitWitness memory _w, string memory _tag) internal returns (string memory) {
        (address chain, , , , ) = reg.chains(_w.chainId);
        ChainSim sim = ChainSim(chain);
        uint256 cv = LegBuilder.commitValue(_w.preimages[0], _w.bundles[0]);
        uint256 batch = sim.inclusion(cv).batchNumber;
        ZKIPLiteRegistry.ChainBatchRootPreimage memory p = sim.preimage(batch);
        vm.serializeBytes32(_tag, "imt_begin", p.imtBegin);
        vm.serializeBytes32(_tag, "imt_end", p.imtEnd);
        vm.serializeUint(_tag, "leaf_count", sim.batchStartLeafCount(batch));
        return _serializeInsertions(_tag, sim.inserts(batch));
    }

    function _serializeInsertions(
        string memory _tag,
        ImtInsertion.Proof[] memory _inserts
    ) internal returns (string memory json) {
        bytes32[] memory values = new bytes32[](_inserts.length);
        bytes32[] memory nextIndices = new bytes32[](_inserts.length);
        bytes32[] memory nextValues = new bytes32[](_inserts.length);
        uint256[] memory indices = new uint256[](_inserts.length);
        string memory lowPaths = "[";
        string memory newPaths = "[";
        for (uint256 i = 0; i < _inserts.length; ++i) {
            values[i] = bytes32(_inserts[i].low.value);
            nextIndices[i] = bytes32(_inserts[i].low.nextIndex);
            nextValues[i] = bytes32(_inserts[i].low.nextValue);
            indices[i] = _inserts[i].lowIndex;
            lowPaths = string.concat(lowPaths, i == 0 ? "" : ",", _pathJson(_inserts[i].lowPath));
            newPaths = string.concat(newPaths, i == 0 ? "" : ",", _pathJson(_inserts[i].newPath));
        }
        vm.serializeBytes32(_tag, "insert_low_value", values);
        vm.serializeBytes32(_tag, "insert_low_next_index", nextIndices);
        vm.serializeBytes32(_tag, "insert_low_next_value", nextValues);
        json = vm.serializeUint(_tag, "insert_low_index", indices);
        // serializeJson replaces the object; append nested arrays to the completed flat witness instead.
        bytes memory prefix = bytes(json);
        prefix[prefix.length - 1] = 0x20;
        json = string.concat(string(prefix), ',"insert_low_path":', lowPaths, '],"insert_new_path":', newPaths, "]}");
    }

    function _pathJson(bytes32[] memory _path) internal pure returns (string memory result) {
        result = "[";
        for (uint256 i = 0; i < _path.length; ++i) {
            result = string.concat(result, i == 0 ? "" : ",", '"', vm.toString(_path[i]), '"');
        }
        result = string.concat(result, "]");
    }

    function _proveClaim(
        uint256 _chainId,
        Credit[] memory _creditList,
        bytes32 _unlockAsset,
        uint256 _unlockAmount,
        string memory _tag
    ) internal returns (bool, bytes32, bytes memory) {
        return _proveClaimWith(ClaimWitness(_chainId, _creditList, _unlockAsset, _unlockAmount), _tag, EVM);
    }

    function _proveClaimWith(
        ClaimWitness memory _w,
        string memory _tag,
        string memory _target
    ) internal returns (bool, bytes32, bytes memory) {
        vm.serializeUint(_tag, "chain_id", _w.chainId);
        vm.serializeUint(_tag, "l1_chain_id", block.chainid);
        vm.serializeUint(_tag, "num_credits", _w.credits.length);
        bytes32[] memory anchors = new bytes32[](2);
        anchors[0] = mroot.historicalRoot(lastPushBlock).root;
        anchors[1] = anchors[0];
        vm.serializeBytes32(_tag, "anchor_roots", anchors);
        uint256[] memory zk = new uint256[](reg.zkipChainCount());
        for (uint256 i = 0; i < zk.length; ++i) {
            zk[i] = reg.zkipChains(i);
        }
        vm.serializeUint(_tag, "zkip_chains", zk);
        vm.serializeBytes32(_tag, "unlock_asset", _w.unlockAsset);
        string memory json = vm.serializeUint(_tag, "unlock_amount", _w.unlockAmount);
        for (uint256 c = 0; c < _w.credits.length; ++c) {
            json = _serializeCredit(_tag, c, _w.credits[c]);
        }
        return _runProver("claim", _w.credits.length <= 1 ? 1 : 2, json, _w.chainId, _tag, _target);
    }

    function _serializeCredit(string memory _o, uint256 _c, Credit memory _cr) internal returns (string memory json) {
        string memory sfx = string.concat("_c", vm.toString(_c));
        vm.serializeBytes(_o, string.concat("bundle", sfx), _cr.bundle);
        vm.serializeBytes(_o, string.concat("preimage", sfx), _cr.pre);
        json = vm.serializeUint(_o, string.concat("credit_leg", sfx), _cr.creditLeg);
        for (uint256 j = 0; j < 2; ++j) {
            json = _serializeLeg(_o, string.concat(sfx, "_l", vm.toString(j)), _cr.legChains[j], _cr.legCvs[j]);
        }
    }

    /// @dev The leg's inclusion data: what the prover reads from the source chain's DA and from L1.
    function _serializeLeg(
        string memory _o,
        string memory _sfx,
        ChainSim _src,
        uint256 _cv
    ) internal returns (string memory) {
        ChainSim.Inclusion memory inc = _src.inclusion(_cv);
        ZKIPLiteRegistry.ChainBatchRootPreimage memory p = _src.preimage(inc.batchNumber);
        uint256 cid = _src.chainId();
        vm.serializeBytes32(_o, string.concat("imt_next_index", _sfx), bytes32(inc.leaf.nextIndex));
        vm.serializeBytes32(_o, string.concat("imt_next_value", _sfx), bytes32(inc.leaf.nextValue));
        vm.serializeUint(_o, string.concat("imt_index", _sfx), inc.index);
        vm.serializeUint(_o, string.concat("imt_height", _sfx), inc.height);
        vm.serializeBytes32(_o, string.concat("imt_path", _sfx), inc.path);
        vm.serializeBytes32(_o, string.concat("cbr_begin", _sfx), p.imtBegin);
        vm.serializeBytes32(
            _o,
            string.concat("cbr_left", _sfx),
            keccak256(abi.encodePacked(p.logsRoot, p.multichainRoot))
        );
        vm.serializeUint(_o, string.concat("batch_number", _sfx), inc.batchNumber);
        vm.serializeUint(_o, string.concat("batch_ts", _sfx), mroot.chainBatchRootTimestamp(cid, inc.batchNumber));
        bytes32[] memory chainPath = mroot.chainTreePath(cid, inc.batchNumber);
        vm.serializeUint(_o, string.concat("chain_height", _sfx), chainPath.length);
        vm.serializeBytes32(_o, string.concat("chain_path", _sfx), chainPath);
        (bytes32[] memory sharedPath, uint256 sharedIndex) = mroot.sharedTreePath(cid);
        vm.serializeUint(_o, string.concat("shared_index", _sfx), sharedIndex);
        vm.serializeUint(_o, string.concat("shared_height", _sfx), sharedPath.length);
        vm.serializeBytes32(_o, string.concat("shared_path", _sfx), sharedPath);
        return vm.serializeUint(_o, string.concat("anchor_sel", _sfx), 0);
    }

    function _runProver(
        string memory _kind,
        uint256 _size,
        string memory _json,
        uint256 _chainId,
        string memory _tag,
        string memory _target
    ) internal returns (bool ok, bytes32 newRoot, bytes memory proof) {
        string memory witness = string.concat(WORK, _tag, ".json");
        vm.writeJson(_json, witness);
        string memory outDir = string.concat(WORK, _tag);
        string memory stateOut = string.concat(WORK, _tag, ".state.json");
        string[] memory cmd = new string[](10);
        cmd[0] = "python3";
        cmd[1] = "-I";
        cmd[2] = "../prover/prove.py";
        cmd[3] = _kind;
        cmd[4] = vm.toString(_size);
        cmd[5] = witness;
        cmd[6] = stateFile[_chainId];
        cmd[7] = stateOut;
        cmd[8] = outDir;
        cmd[9] = _target;
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode != 0) {
            console2.log(string.concat(_tag, ": prover rejected the witness"));
            console2.log(string(r.stderr));
            return (false, bytes32(0), "");
        }
        ok = true;
        newRoot = bytes32(r.stdout);
        proof = vm.readFileBinary(string.concat(outDir, "/proof"));
        pendingState[_chainId] = stateOut;
    }

    // ------------------------------------------------------------------------- aggregated path

    /// @dev A chain proves a debit for the aggregator with its smallest supported size class.
    function _proveDebitRec(
        ChainSim _sim,
        uint256 _batch,
        bytes[] memory _bundles,
        bytes[] memory _preimages,
        uint256[] memory _legs,
        bytes32 _lockAsset,
        uint256 _lockAmount,
        string memory _tag
    ) internal returns (Inner memory inner) {
        inner.chainId = _sim.chainId();
        DebitWitness memory w = DebitWitness(inner.chainId, _bundles, _preimages, _legs, _lockAsset, _lockAmount);
        uint256 size = _bundles.length <= 1 ? 1 : 4;
        (bool ok, bytes32 newRoot, ) = _proveDebitWith(w, _tag, size, REC);
        assertTrue(ok, string.concat("prover failed: ", _tag));
        inner.kind = SLOT_DEBIT;
        inner.circuit = size == 1 ? "debit_1" : "debit_4";
        inner.dir = string.concat(WORK, _tag);
        inner.stateOut = pendingState[inner.chainId];
        inner.debit = _submission(_sim, _batch, _lockAsset, _lockAmount, newRoot, "");
    }

    /// @dev A chain proves a claim for the aggregator: claim_1 or claim_2, noir-recursive target.
    function _proveClaimRec(
        uint256 _chainId,
        Credit[] memory _creditList,
        bytes32 _unlockAsset,
        uint256 _unlockAmount,
        string memory _tag
    ) internal returns (Inner memory inner) {
        (bool ok, bytes32 newRoot, ) = _proveClaimWith(
            ClaimWitness(_chainId, _creditList, _unlockAsset, _unlockAmount),
            _tag,
            REC
        );
        assertTrue(ok, string.concat("prover failed: ", _tag));
        inner.kind = SLOT_CLAIM;
        inner.circuit = _creditList.length <= 1 ? "claim_1" : "claim_2";
        inner.dir = string.concat(WORK, _tag);
        inner.chainId = _chainId;
        inner.stateOut = pendingState[_chainId];
        inner.claim = _claimSubmission(_chainId, _creditList.length, _unlockAsset, _unlockAmount, newRoot, "");
    }

    /// @dev The aggregator: verifies each inner proof natively, drops failures, proves a 4- or 16-slot window. Returns the
    /// submission over the included statements (slot order = input order) and which inputs were included.
    function _aggregate(
        Inner[] memory _inners,
        string memory _tag
    ) internal returns (ZKIPLiteRegistry.AggregatedSubmission memory s, bytes memory included) {
        string memory slots;
        for (uint256 i = 0; i < _inners.length; ++i) {
            slots = string.concat(
                slots,
                i == 0 ? "" : ",",
                '{"circuit":"',
                _inners[i].circuit,
                '","dir":"',
                _inners[i].dir,
                '"}'
            );
        }
        string memory manifest = string.concat(WORK, _tag, ".manifest.json");
        vm.writeFile(manifest, string.concat('{"slots":[', slots, "]}"));
        string memory outDir = string.concat(WORK, _tag);
        string[] memory cmd = _prover("aggregate");
        cmd = _push(_push(cmd, manifest), outDir);
        included = vm.ffi(cmd);

        s.proof = vm.readFileBinary(string.concat(outDir, "/proof"));
        s.vkCommitments = _readFields(string.concat(outDir, "/vk_commitments"));
        s.publicInputs = _readFields(string.concat(outDir, "/public_inputs"));
        uint256 debits;
        uint256 claims;
        for (uint256 i = 0; i < _inners.length; ++i) {
            if (included[i] == 0x00) {
                continue;
            }
            if (_inners[i].kind == SLOT_DEBIT) {
                ++debits;
            } else {
                ++claims;
            }
        }
        s.kinds = new uint8[](s.vkCommitments.length);
        s.debits = new ZKIPLiteRegistry.DebitSubmission[](debits);
        s.claims = new ZKIPLiteRegistry.ClaimSubmission[](claims);
        (uint256 slot, uint256 d, uint256 c) = (0, 0, 0);
        for (uint256 i = 0; i < _inners.length; ++i) {
            if (included[i] == 0x00) {
                continue;
            }
            s.kinds[slot++] = _inners[i].kind;
            if (_inners[i].kind == SLOT_DEBIT) {
                s.debits[d++] = _inners[i].debit;
            } else {
                s.claims[c++] = _inners[i].claim;
            }
        }
    }

    function _readFields(string memory _path) internal view returns (bytes32[] memory result) {
        bytes memory raw = vm.readFileBinary(_path);
        result = new bytes32[](raw.length / 32);
        for (uint256 i = 0; i < result.length; ++i) {
            bytes32 word;
            assembly {
                word := mload(add(add(raw, 32), mul(i, 32)))
            }
            result[i] = word;
        }
    }

    function _submitAggregated(ZKIPLiteRegistry.AggregatedSubmission memory _s, string memory _label) internal {
        uint256 g = gasleft();
        reg.submitAggregated(_s);
        _logGas(string.concat(_label, ": submitAggregated"), g - gasleft(), abi.encodeCall(reg.submitAggregated, (_s)));
    }

    /// @dev After its statement landed on L1, the chain adopts the private state it proved.
    function _adopt(Inner memory _inner) internal {
        stateFile[_inner.chainId] = _inner.stateOut;
    }

    // ------------------------------------------------------------------------------------- misc

    function _prover(string memory _cmd) internal pure returns (string[] memory cmd) {
        cmd = new string[](4);
        cmd[0] = "python3";
        cmd[1] = "-I";
        cmd[2] = "../prover/prove.py";
        cmd[3] = _cmd;
    }

    function _push(string[] memory _a, string memory _x) internal pure returns (string[] memory b) {
        b = new string[](_a.length + 1);
        for (uint256 i = 0; i < _a.length; ++i) {
            b[i] = _a[i];
        }
        b[_a.length] = _x;
    }

    function _logGas(string memory _label, uint256 _execution, bytes memory _calldata) internal pure {
        uint256 calldataGas;
        for (uint256 i = 0; i < _calldata.length; ++i) {
            calldataGas += _calldata[i] == 0 ? ZERO_BYTE_GAS : NONZERO_BYTE_GAS;
        }
        console2.log(_label);
        console2.log("  execution gas / calldata gas / calldata bytes", _execution, calldataGas, _calldata.length);
    }

    function _one(uint256 _x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = _x;
    }

    function _oneB(bytes memory _x) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = _x;
    }
}
