"""Controlled circuit experiments, never imported by protocol or PoC contracts.

Generate variants from the checked-in circuits so accounting, nullifiers, public inputs,
path depths and proof-system settings stay identical. See README.md for the trust boundary.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
POC = HERE.parent
BASELINE_COMMIT = "cb7382cdb486beb0a6b5ba352cf1a79c2560e497"
WORK = POC / "work" / "benchmarks"
BASELINE = WORK / "baseline" / "zkip-poc"
CIRCUITS = ("debit_1", "debit_4", "claim_1", "claim_2")
REFERENCE_FILES = ["prover/prove.py", "prover/poseidon2.py", "prover/poseidon2_bn254_params.json", "prover/keccak.py",
                   "circuits/zkip_lite/src/lib.nr", "circuits/zkip_lite/Nargo.toml"]
REFERENCE_FILES += [f"circuits/{name}/{path}" for name in CIRCUITS for path in ("src/main.nr", "Nargo.toml")]
for relative in REFERENCE_FILES:
    destination = BASELINE / relative
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(subprocess.check_output(
            ["git", "show", f"{BASELINE_COMMIT}:zkip-poc/{relative}"], cwd=POC))
sys.path.insert(0, str(BASELINE / "prover"))
import prove as reference

VARIANTS = ("legacy_keccak", "proof_keccak", "compact_keccak", "compact_blake2s", "compact_blake3_source", "compact_blake3", "compact_poseidon2")
TRANSFER_WORDS = 10
WORD_BYTES = 32
TRANSFER_BYTES = TRANSFER_WORDS * WORD_BYTES
LEGACY_BUNDLE_BYTES = 1600
L1, A, B = 31337, 270270, 270271
TIMESTAMP, DEADLINE = 1_800_000_000, 1_800_003_600
NTV = 0x10004
VERSION = 1 << 248
SENDER, RECIPIENT = 0xA11CE, 0xB0B
RESERVED_SUBTREE = b"".join(x.to_bytes(8, "little") for x in (
    0x8f6f7c955119c1b4, 0x46b2d61cf64a2c64, 0xee07c67fdcc6fe40, 0x300d41929ea90682))
IMT_EMPTY_LEAF = reference.keccak256(b"zkSync:IndexedMerkleTree:emptyLeaf")


def word(value):
    return value if isinstance(value, bytes) else value.to_bytes(WORD_BYTES, "big")


def words(*values):
    return b"".join(map(word, values))


def protocol_hash(variant, data):
    algorithm = variant.split("_")[1]
    if algorithm == "blake2s":
        return hashlib.blake2s(data).digest()
    if algorithm == "blake3":
        import blake3
        return blake3.blake3(data).digest()
    if algorithm == "poseidon2":
        assert len(data) % 16 == 0
        limbs = [int.from_bytes(data[i:i + 16], "little") for i in range(0, len(data), 16)]
        return reference.p2.hash_many(limbs).to_bytes(WORD_BYTES, "little")
    return reference.keccak256(data)


def settlement_hash(variant, data):
    return reference.keccak256(data) if variant.endswith("_source") else protocol_hash(variant, data)


def asset_id(origin=L1, token=0x1234):
    return reference.keccak256(words(origin, NTV, token))


def transfer(variant, amount, nonce, source=A, destination=B):
    asset = asset_id()
    salt = reference.keccak256(words(SENDER, nonce))
    if variant.startswith("compact_"):
        return words(VERSION, source, destination, asset, amount, L1, 0x1234, SENDER, RECIPIENT, salt)
    # The same fixed ABI template as LegBuilder.bundle, including dynamic-data offsets.
    out = bytearray(LEGACY_BUNDLE_BYTES)
    fields = {
        0: 32, 0x20: VERSION, 0x40: source, 0x60: destination, 0x80: asset_id(1, 1), 0xa0: salt,
        0xc0: 0xe0, 0xe0: 0x540, 0x100: 1, 0x120: 32, 0x140: VERSION, 0x160: 0,
        0x180: 0x10003, 0x1a0: 0x10003, 0x1c0: 0, 0x1e0: 0xc0, 0x200: 804,
        0x224: source, 0x244: asset, 0x264: 0x60, 0x284: 672, 0x2a4: SENDER,
        0x2c4: RECIPIENT, 0x2e4: 0x1234, 0x304: amount, 0x324: 0xa0, 0x344: 449,
        0x365: L1, 0x385: 0x80, 0x3a5: 0x100, 0x3c5: 0x180,
        0x3e5: 96, 0x405: 32, 0x425: 4, 0x465: 96, 0x485: 32, 0x4a5: 4,
        0x4e5: 32, 0x505: 6, 0x560: 0x80, 0x580: 0xa0, 0x5a0: 0, 0x5c0: nonce, 0x5e0: 0,
    }
    for offset, value in fields.items():
        out[offset:offset + WORD_BYTES] = word(value)
    out[0x220:0x224] = bytes.fromhex("9c884fd1")
    out[0x364] = 1
    out[0x445:0x449] = b"TEST"
    out[0x4c5:0x4c9] = b"TEST"
    return bytes(out)


def flow(variant, nonce):
    bundle = transfer(variant, 10, nonce)
    other = transfer(variant, 7, nonce, B, A)
    hashes = [protocol_hash(variant, bundle), protocol_hash(variant, other)]
    leg = int(hashes[0] > hashes[1])
    sources = [A, B]
    if leg:
        hashes.reverse()
        sources.reverse()
    pre = words(32, VERSION, DEADLINE, L1, 0xa0, 0x100, 2, *hashes, 2, *sources)
    fid = protocol_hash(variant, pre)
    cvs = [protocol_hash(variant, reference.TAG + bytes(28) + fid + h) for h in hashes]
    return {"bundle": bundle, "pre": pre, "leg": leg, "cvs": cvs, "sources": sources}


def path_root(variant, leaf, index, siblings, height, settlement=False):
    h = settlement_hash if settlement else protocol_hash
    for i, sibling in enumerate(siblings[:height]):
        leaf = h(variant, sibling + leaf if (index >> i) & 1 else leaf + sibling)
    return leaf


def inclusion(variant, cv, source, tag):
    h = lambda data: protocol_hash(variant, data)
    sh = lambda data: settlement_hash(variant, data)
    path = lambda depth, label: [h(words(tag, label, i)) for i in range(depth)]
    imt_path = path(reference.D_IMT, 1)
    chain_path = path(reference.D_CHAIN, 2)
    shared_path = path(reference.D_SHARED, 3)
    next_index, next_value = bytes(32), bytes(32)
    imt_root = path_root(variant, h(cv + next_index + next_value), 1, imt_path, reference.D_IMT)
    begin, left = h(words(tag, 4)), h(words(tag, 5))
    batch_root = sh(sh(left + sh(begin + imt_root)) + RESERVED_SUBTREE)
    batch_padding = reference.keccak256(b"zkSync:BatchLeaf")
    chain_padding = reference.keccak256(b"zkSync:ChainIdLeaf")
    batch_leaf = sh(batch_padding + batch_root + words(1, TIMESTAMP))
    chain_root = path_root(variant, batch_leaf, 1, chain_path, reference.D_CHAIN, settlement=True)
    shared_leaf = sh(chain_padding + chain_root + word(source))
    root = path_root(variant, shared_leaf, 1, shared_path, reference.D_SHARED, settlement=True)
    return root, {
        "imt_next_index": next_index, "imt_next_value": next_value, "imt_index": 1,
        "imt_height": reference.D_IMT, "imt_path": imt_path, "cbr_begin": begin, "cbr_left": left,
        "batch_number": 1, "batch_ts": TIMESTAMP, "chain_height": reference.D_CHAIN,
        "chain_path": chain_path, "shared_index": 1, "shared_height": reference.D_SHARED,
        "shared_path": shared_path,
    }


def opened(variant, bundle, pre, leg):
    hashes = [reference.word(pre, 0xe0), reference.word(pre, 0x100)]
    fid = protocol_hash(variant, pre)
    cv = protocol_hash(variant, reference.TAG + bytes(28) + fid + hashes[leg])
    asset_offset, amount_offset, origin_offset = (96, 128, 160) if variant.startswith("compact_") else (0x244, 0x304, 0x365)
    return {"own_cv": cv, "asset": reference.field(reference.word(bundle, asset_offset)),
            "amount": int.from_bytes(reference.word(bundle, amount_offset), "big"),
            "origin": int.from_bytes(reference.word(bundle, origin_offset), "big")}


class Imt:
    def __init__(self, variant):
        self.variant = variant
        self.leaves = [[0, 0, 0]]
        self.zeros = [IMT_EMPTY_LEAF]
        for _ in range(reference.D_IMT):
            self.zeros.append(protocol_hash(variant, self.zeros[-1] * 2))

    def levels(self):
        level = [protocol_hash(self.variant, words(*leaf)) for leaf in self.leaves]
        result = [level]
        height = (len(level) - 1).bit_length()
        for i in range(height):
            padded = level + [self.zeros[i]] if len(level) % 2 else level
            level = [protocol_hash(self.variant, padded[j] + padded[j + 1]) for j in range(0, len(padded), 2)]
            result.append(level)
        return result

    def root(self):
        return self.levels()[-1][0]

    def path(self, index):
        result = []
        for i, level in enumerate(self.levels()[:-1]):
            sibling = (index >> i) ^ 1
            result.append(level[sibling] if sibling < len(level) else self.zeros[i])
        return result

    def insert(self, value):
        low_index = max((i for i, leaf in enumerate(self.leaves) if leaf[0] < value), key=lambda i: self.leaves[i][0])
        low = self.leaves[low_index].copy()
        if low[2] != 0 and not value < low[2]:
            raise ValueError("duplicate IMT value")
        low_path = self.path(low_index)
        count = len(self.leaves)
        self.leaves[low_index] = [low[0], count, value]
        self.leaves.append([value, low[1], low[2]])
        return {"insert_low_value": word(low[0]), "insert_low_next_index": word(low[1]),
                "insert_low_next_value": word(low[2]), "insert_low_index": low_index,
                "insert_low_path": low_path, "insert_new_path": self.path(count)}


def insertion_inputs(variant, fs, size):
    tree = Imt(variant)
    bh, bl = reference.hi_lo(tree.root())
    inserts = [tree.insert(int.from_bytes(f["cvs"][f["leg"]], "big")) for f in fs]
    eh, el = reference.hi_lo(tree.root())
    toml = ["imt_begin_hi = " + reference.q(bh), "imt_begin_lo = " + reference.q(bl),
            "imt_end_hi = " + reference.q(eh), "imt_end_lo = " + reference.q(el),
            "leaf_count = 1", 'reserved = ["0x0", "0x0", "0x0"]']
    inserts += [inserts[0]] * (size - len(inserts))
    for key in inserts[0]:
        values = [entry[key] for entry in inserts]
        if key.endswith("path"):
            encoded = reference.arr([reference.arr([reference.toml_lanes(x) for x in p + [bytes(32)] * (reference.D_IMT - len(p))]) for p in values])
        elif key == "insert_low_index":
            encoded = str(values)
        else:
            encoded = reference.arr([reference.toml_lanes(v) for v in values])
        toml.append(key + " = " + encoded)
    return toml


def witness(variant, name):
    kind, size = name.split("_")
    size = int(size)
    # Reuse the original witness/state builders, replacing only the commitment-opening mirror.
    reference.open_leg = lambda bundle, pre, leg: opened(variant, bundle, pre, leg)
    state = reference.State()
    state.toml_prev = state.toml()
    f = flow(variant, 1)
    if kind == "debit":
        fs = [flow(variant, i + 1) for i in range(size)]
        w = {"chain_id": A, "l1_chain_id": L1, "num_legs": size,
             "bundles": [x["bundle"].hex() for x in fs], "preimages": [x["pre"].hex() for x in fs],
             "leg_index": [x["leg"] for x in fs], "lock_asset": asset_id().hex(), "lock_amount": 10 * size}
        w["bundles"] = ["0x" + x for x in w["bundles"]]
        w["preimages"] = ["0x" + x for x in w["preimages"]]
        w["lock_asset"] = "0x" + w["lock_asset"]
        toml = reference.debit(size, w, state, None, None)
        if variant != "legacy_keccak":
            toml = [line for line in toml if not line.startswith(("cv_hi =", "cv_lo ="))]
            toml += insertion_inputs(variant, fs, size)
    else:
        # Synthetic siblings isolate circuit cost; these roots are NOT evidence of accepted L1
        # settlement. claim_2 below shares two anchors using sibling IMT leaves (see README).
        fs = [flow(variant, i + 1) for i in range(size)]
        w = {"chain_id": B, "l1_chain_id": L1, "num_credits": size,
             "unlock_asset": "0x" + asset_id().hex(), "unlock_amount": 10 * size,
             "zkip_chains": [A, B, 0, 0]}
        roots = []
        for c, f in enumerate(fs):
            w.update({f"bundle_c{c}": "0x" + f["bundle"].hex(),
                      f"preimage_c{c}": "0x" + f["pre"].hex(), f"credit_leg_c{c}": f["leg"]})
            for j in range(2):
                root, inc = inclusion(variant, f["cvs"][j], f["sources"][j], c * 2 + j + 1)
                roots.append(root)
                for key, value in inc.items():
                    if isinstance(value, bytes):
                        value = "0x" + value.hex()
                    elif isinstance(value, list):
                        value = ["0x" + x.hex() for x in value]
                    w[f"{key}_c{c}_l{j}"] = value
                w[f"anchor_sel_c{c}_l{j}"] = c * 2 + j
        if size == 2:
            for j in range(2):
                # Make the two inclusion paths converge at IMT level 0: leaves 0 and 1 are siblings.
                ordered_cvs = [fs[c]["cvs"][fs[c]["leg"] if j == 0 else 1 - fs[c]["leg"]] for c in range(size)]
                leaves = [protocol_hash(variant, cv + bytes(64)) for cv in ordered_cvs]
                for c, f in enumerate(fs):
                    slot = f["leg"] if j == 0 else 1 - f["leg"]
                    source = A if j == 0 else B
                    root, inc = inclusion(variant, ordered_cvs[c], source, j + 1)
                    inc["imt_index"] = c
                    inc["imt_path"][0] = leaves[1 - c]
                    # Recompute the authenticated root with this path, without inventing a shared root.
                    root = inclusion_root(variant, ordered_cvs[c], source, inc)
                    for key, value in inc.items():
                        if isinstance(value, bytes):
                            value = "0x" + value.hex()
                        elif isinstance(value, list):
                            value = ["0x" + x.hex() for x in value]
                        w[f"{key}_c{c}_l{slot}"] = value
                    w[f"anchor_sel_c{c}_l{slot}"] = j
                    if c == 0:
                        roots[j] = root
                    else:
                        assert roots[j] == root
        w["anchor_roots"] = ["0x" + root.hex() for root in roots[:2]]
        toml = reference.claim(size, w, state, None, None)
    return "\n".join(toml) + "\n", state


def inclusion_root(variant, cv, source, inc):
    h = lambda data: protocol_hash(variant, data)
    sh = lambda data: settlement_hash(variant, data)
    imt = path_root(variant, h(cv + inc["imt_next_index"] + inc["imt_next_value"]),
                    inc["imt_index"], inc["imt_path"], inc["imt_height"])
    batch = sh(sh(inc["cbr_left"] + sh(inc["cbr_begin"] + imt)) + RESERVED_SUBTREE)
    leaf = sh(reference.keccak256(b"zkSync:BatchLeaf") + batch + words(inc["batch_number"], inc["batch_ts"]))
    chain = path_root(variant, leaf, inc["batch_number"], inc["chain_path"], inc["chain_height"], settlement=True)
    return path_root(variant, sh(reference.keccak256(b"zkSync:ChainIdLeaf") + chain + word(source)),
                     inc["shared_index"], inc["shared_path"], inc["shared_height"], settlement=True)


def hash_function(algorithm):
    if algorithm == "keccak":
        return "pub fn protocol_hash_lanes<let NL: u32>(_msg: [u64; NL]) -> [u64; 4] { keccak_lanes(_msg) }"
    if algorithm == "poseidon2":
        return """pub fn protocol_hash_lanes<let NL: u32>(_msg: [u64; NL]) -> [u64; 4] {
    std::static_assert(NL % 2 == 0, "128-bit limbs");
    let mut limbs: [Field; NL / 2] = [0; NL / 2];
    for i in 0..NL / 2 { limbs[i] = (_msg[2 * i] as Field) + (_msg[2 * i + 1] as Field) * TWO_POW_64; }
    bytes_to_lanes::<32, 4>(p2_hash_many(limbs).to_le_bytes::<32>())
}"""
    return """pub fn protocol_hash_lanes<let NL: u32>(_msg: [u64; NL]) -> [u64; 4] {
    let mut bytes: [u8; NL * 8] = [0; NL * 8];
    for i in 0..NL {
        let lane: [u8; 8] = (_msg[i] as Field).to_le_bytes();
        for j in 0..8 { bytes[8 * i + j] = lane[j]; }
    }
    bytes_to_lanes::<32, 4>(std::hash::%s(bytes))
}""" % algorithm


def generate(variant, names):
    root = WORK / variant
    lib = root / "zkip_lite/src"
    lib.mkdir(parents=True, exist_ok=True)
    circuit_root = reference.CIRCUITS if variant == "legacy_keccak" else POC / "circuits"
    source = (circuit_root / "zkip_lite/src/lib.nr").read_text()
    for extra in circuit_root.joinpath("zkip_lite/src").glob("*.nr"):
        if extra.name != "lib.nr":
            shutil.copyfile(extra, lib / extra.name)
    algorithm = variant.split("_")[1]
    source = re.sub(r"pub fn protocol_hash_lanes<let NL: u32>\(_msg: \[u64; NL\]\) -> \[u64; 4\] \{\n    keccak_lanes\(_msg\)\n\}\n", "", source)
    if variant != "legacy_keccak":
        zeros = Imt(variant).zeros
        constants = "pub global IMT_MAX_LEAVES: u32 = 65536;\n"
        constants += "pub global IMT_ZEROS: [[u64; 4]; 17] = " + str([reference.lanes(z) for z in zeros]) + ";\n"
        (lib / "imt_constants.nr").write_text(constants)
    # Keep Keccak for canonical NTV asset IDs; change only protocol commitments and paths.
    start = source.index("pub fn commit_value(")
    end = source.index("pub struct Opened", start)
    source = source[:start] + source[start:end].replace("keccak_lanes(", "protocol_hash_lanes(") + source[end:]
    start = source.index("pub fn shared_root(")
    source = source[:start] + source[start:].replace("keccak_lanes(", "protocol_hash_lanes(")
    if variant.endswith("_source"):
        split = source.index("    let live =", start)
        source = source[:split] + source[split:].replace("protocol_hash_lanes(", "keccak_lanes(").replace("keccak_pair(", "settlement_pair(").replace("merkle_var(", "settlement_merkle(")
        merkle_start = source.index("pub fn merkle_var<")
        merkle_end = source.index("// --------------------------------------------------------------------------------------- Poseidon2", merkle_start)
        source += "\n" + source[merkle_start:merkle_end].replace("merkle_var", "settlement_merkle").replace("keccak_pair", "settlement_pair")
        source += "\npub fn settlement_pair(_a: [u64; 4], _b: [u64; 4]) -> [u64; 4] { keccak_lanes([_a[0], _a[1], _a[2], _a[3], _b[0], _b[1], _b[2], _b[3]]) }\n"
    source = source.replace("    keccak_lanes([a[0]", "    protocol_hash_lanes([a[0]")
    if variant.startswith("compact_"):
        source = source.replace("pub global BUNDLE_LEN: u32 = 1600;", f"pub global BUNDLE_LEN: u32 = {TRANSFER_BYTES};")
        source += "\npub global BUNDLE_LANES: u32 = BUNDLE_LEN / 8;\n"
        start = source.index("fn check_bundle_template(")
        end = source.index("/// abi.encode(AtomicFlowPreimage)", start)
        source = source[:start] + source[end:]
        start = source.index("pub fn open_leg(")
        end = source.index("pub fn cv_key(", start)
        source = source[:start] + (HERE / "compact.nr").read_text() + "\n" + source[end:]
    source += "\n" + hash_function(algorithm) + "\n"
    # Independent Python hash implementations supply known answers, including block boundaries.
    source += "\n#[test]\nfn hash_vectors() {\n"
    for length in (32, 64, 96, 128, TRANSFER_BYTES, reference.D_IMT * 32):
        data = bytes(i % 251 for i in range(length))
        expected = reference.lanes(protocol_hash(variant, data))
        source += f"    assert(protocol_hash_lanes({reference.lanes(data)}) == {expected});\n"
    source += "}\n"
    (lib / "lib.nr").write_text(source)
    shutil.copyfile(reference.CIRCUITS / "zkip_lite/Nargo.toml", root / "zkip_lite/Nargo.toml")
    for name in names:
        dst = root / name / "src"
        dst.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(circuit_root / name / "src/main.nr", dst / "main.nr")
        shutil.copyfile(reference.CIRCUITS / name / "Nargo.toml", dst.parent / "Nargo.toml")
        toml, _ = witness(variant, name)
        (dst.parent / "Prover.toml").write_text(toml)
    (root / "Nargo.toml").write_text("[workspace]\nmembers = " + json.dumps(["zkip_lite", *names]) + "\n")
    return root


def command(args, cwd, env):
    started = time.monotonic()
    timed = sys.platform == "darwin"
    cmd = (["/usr/bin/time", "-l"] if timed else []) + list(map(str, args))
    result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    seconds = time.monotonic() - started
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}")
    match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
    return result.stdout, seconds, int(match[1]) if match else None


def prepare_verifier_bench(rows, bb, crs, env, forge_std):
    root = WORK / "verifiers"
    (root / "src").mkdir(parents=True, exist_ok=True)
    (root / "test").mkdir(exist_ok=True)
    (root / "fixtures").mkdir(exist_ok=True)
    names = []
    for row in rows:
        variant, circuit = row["variant"], row["circuit"]
        name = variant + "_" + circuit
        names.append(name)
        out = WORK / variant / "proofs" / circuit
        command([bb, "write_solidity_verifier", "-k", out / "vk", "-o", root / "src" / f"{name}.sol",
                 "-t", "evm", "--optimized", "-c", crs], root, env)
        pi = (out / "public_inputs").read_bytes()
        fixture = {"proof": "0x" + (out / "proof").read_bytes().hex(),
                   "public_inputs": ["0x" + pi[i:i + WORD_BYTES].hex() for i in range(0, len(pi), WORD_BYTES)]}
        (root / "fixtures" / f"{name}.json").write_text(json.dumps(fixture) + "\n")
    (root / "manifest.json").write_text(json.dumps({"names": names}) + "\n")
    shutil.copyfile(HERE / "VerifierBench.t.sol", root / "test/VerifierBench.t.sol")
    config = f"""[profile.default]
src = "src"
test = "test"
solc_version = "0.8.28"
evm_version = "prague"
optimizer = true
optimizer_runs = 200
# Match the original PoC. Runtime sizes are reported: these verifiers may exceed EIP-170.
code_size_limit = 1000000
gas_limit = 2000000000
allow_paths = [{json.dumps(str(forge_std.parent))}]
remappings = [{json.dumps('forge-std/=' + str(forge_std / 'src') + '/')}]
fs_permissions = [{{ access = "read", path = "./" }}]
"""
    (root / "foundry.toml").write_text(config)
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(VARIANTS))
    parser.add_argument("--circuits", nargs="+", choices=CIRCUITS, default=list(CIRCUITS))
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--large-repetitions", type=int, help="Optional sample count for debit_4 and claim_2")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--gates-only", action="store_true")
    parser.add_argument("--evm", action="store_true", help="Verify real proofs in Forge and measure verifier-only gas")
    parser.add_argument("--forge-std", type=Path, default=POC.parent / "lib/forge-std")
    args = parser.parse_args()
    if args.threads < 1 or args.repetitions < 1 or (args.large_repetitions is not None and args.large_repetitions < 1):
        parser.error("threads and repetitions must be positive")
    env = dict(os.environ, HARDWARE_CONCURRENCY=str(args.threads))
    nargo, bb = os.environ.get("NARGO", "nargo"), os.environ.get("BB", "bb")
    crs = os.environ.get("BB_CRS", str(POC / "work/crs"))
    result_file = WORK / "results.json"
    results = {"machine": platform.platform(), "threads": args.threads, "repetitions": args.repetitions,
               "baseline_commit": BASELINE_COMMIT, "measurements": []}
    results["large_repetitions"] = args.large_repetitions or args.repetitions
    results["experiment_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=POC, text=True).strip()
    if sys.platform == "darwin":
        results["cpu"] = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        results["ram_bytes"] = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
    if not args.prepare_only:
        results["nargo"] = command([nargo, "--version"], HERE, env)[0].strip()
        results["bb"] = command([bb, "--version"], HERE, env)[0].strip()
    for variant in args.variants:
        print(f"Preparing {variant}", flush=True)
        root = generate(variant, args.circuits)
        if args.prepare_only:
            continue
        command([nargo, "test", "--package", "zkip_lite"], root, env)
        command([nargo, "compile", "--workspace"], root, env)
        for name in args.circuits:
            print(f"Measuring {variant}/{name}", flush=True)
            bytecode = root / "target" / f"{name}.json"
            out = root / "proofs" / name
            out.mkdir(parents=True, exist_ok=True)
            gates, _, _ = command([bb, "gates", "-b", bytecode, "-t", "evm"], root, env)
            row = {"variant": variant, "circuit": name, "gates": json.loads(gates)}
            row["bytecode_sha256"] = hashlib.sha256(bytecode.read_bytes()).hexdigest()
            if not args.gates_only:
                command([nargo, "execute", "--package", name, name], root, env)
                command([bb, "write_vk", "-b", bytecode, "-o", out, "-t", "evm", "-c", crs], root, env)
                samples = []
                repetitions = results["large_repetitions"] if name in ("debit_4", "claim_2") else args.repetitions
                for _ in range(repetitions):
                    _, seconds, rss = command([bb, "prove", "-b", bytecode, "-w", root / "target" / f"{name}.gz",
                                               "-k", out / "vk", "-o", out, "-t", "evm", "-c", crs], root, env)
                    command([bb, "verify", "-k", out / "vk", "-p", out / "proof", "-i", out / "public_inputs",
                             "-t", "evm", "-c", crs], root, env)
                    samples.append({"prove_s": seconds, "peak_rss_bytes": rss})
                row.update(samples=samples, median_prove_s=statistics.median(x["prove_s"] for x in samples),
                           proof_bytes=(out / "proof").stat().st_size,
                           public_input_bytes=(out / "public_inputs").stat().st_size)
            results["measurements"].append(row)
            result_file.write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(row), flush=True)
    if args.evm and not (args.prepare_only or args.gates_only):
        root = prepare_verifier_bench(results["measurements"], bb, crs, env, args.forge_std.resolve())
        output, _, _ = command(["forge", "test", "--threads", "1", "-vv"], root, env)
        (root / "gas.log").write_text(output)
        current = None
        by_name = {r["variant"] + "_" + r["circuit"]: r for r in results["measurements"]}
        for line in output.splitlines():
            match = re.search(r"BENCH (\w+)", line)
            if match:
                current = by_name[match[1]]
            match = re.search(r"(execution_gas|calldata_gas|transaction_gas|verifier_runtime_bytes)\s+(\d+)", line)
            if match and current is not None:
                current[match[1]] = int(match[2])
        if any("transaction_gas" not in row for row in results["measurements"]):
            raise RuntimeError("Missing Forge gas measurements; inspect " + str(root / "gas.log"))
        results["gas_scope"] = "standalone verifier, including calldata and 21k base; excludes registry/settlement"
        result_file.write_text(json.dumps(results, indent=2) + "\n")
    print(result_file, flush=True)


if __name__ == "__main__":
    main()
