"""Prover bridge for the ZKIP-lite PoC, called by the forge tests through vm.ffi.

  python3 -I prove.py setup                                   # compile circuits, write VKs and Solidity verifiers
  python3 -I prove.py init-root                               # state root of an empty ZKIP state
  python3 -I prove.py debit <size> <witness.json> <state_in> <state_out> <out_dir>
  python3 -I prove.py claim <size> <witness.json> <state_in> <state_out> <out_dir>

The forge test supplies the public L1/L2 data (bundles, flow preimages, IMT and message-root paths) as a flat
witness JSON. This script adds the chain's private ZKIP state (balances and the consumed set), writes the
Prover.toml, runs nargo and bb, and prints the new state root as 0x-hex on stdout (the only stdout output, so
vm.ffi can decode it). An `<state_in>` of "-" means the empty state.

Tools come from the environment: NARGO and BB (default: on PATH), BB_CRS (bb's CRS directory, default ~/.bb-crs),
ZKIP_PROVER_THREADS (default 14) and ZKIP_CMD_WRAPPER (an optional command that every nargo and bb call runs under,
e.g. a sandbox that denies network access).
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import poseidon2 as p2  # noqa: E402
from keccak import keccak256  # noqa: E402

POC = HERE.parent
CIRCUITS = POC / "circuits"
VK_DIR = POC / "work" / "vk"
VERIFIERS = POC / "contracts" / "src" / "verifiers"
NARGO = os.environ.get("NARGO", "nargo")
BB = os.environ.get("BB", "bb")
CRS = os.environ.get("BB_CRS", str(Path.home() / ".bb-crs"))
WRAPPER = os.environ.get("ZKIP_CMD_WRAPPER")
METRICS = POC / "work" / "metrics.jsonl"
THREADS = os.environ.get("ZKIP_PROVER_THREADS", "14")

P = p2.P
MAX_ASSETS, NULL_DEPTH = 8, 24
D_IMT, D_CHAIN, D_SHARED = 16, 18, 7
TAG = bytes.fromhex("3445134c")
CIRCUIT_NAMES = ["debit_1", "debit_4", "claim_1", "claim_2"]


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def run(cmd, cwd=None, timed=False):
    env = dict(os.environ, HARDWARE_CONCURRENCY=THREADS)
    full = ([WRAPPER] if WRAPPER else []) + [str(c) for c in cmd]
    timed = timed and sys.platform == "darwin"  # peak RSS via BSD time
    if timed:
        full = ["/usr/bin/time", "-l"] + full
    t0 = time.monotonic()
    p = subprocess.run(full, cwd=cwd, env=env, capture_output=True, text=True)
    wall = time.monotonic() - t0
    if p.returncode != 0:
        log(p.stdout[-3000:], p.stderr[-3000:])
        raise SystemExit("command failed: " + " ".join(map(str, cmd[:3])))
    rss = None
    if timed:
        m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
        rss = int(m.group(1)) if m else None
    return p.stdout, wall, rss


# ------------------------------------------------------------------------------------- encodings

def b32(x):
    return bytes.fromhex(x[2:]) if isinstance(x, str) else int(x).to_bytes(32, "big")


def lanes(b):
    return [int.from_bytes(b[8 * i: 8 * i + 8], "little") for i in range(len(b) // 8)]


def hi_lo(b):
    return int.from_bytes(b[:16], "big"), int.from_bytes(b[16:], "big")


def field(b):
    return int.from_bytes(b, "big") % P


def word(buf, off):
    return buf[off: off + 32]


def q(x):
    return '"0x%x"' % (x % P if x >= 0 else (x % P))


def arr(xs):
    return "[" + ", ".join(xs) + "]"


def toml_bytes(b):
    return "[" + ", ".join(str(x) for x in b) + "]"


def toml_lanes(b):
    return arr(['"0x%x"' % l for l in lanes(b)])


def pad_path(path, depth):
    path = [b32(x) for x in path]
    return path + [bytes(32)] * (depth - len(path))


# --------------------------------------------------------------------------------- private state

class NullTree:
    """Append-only Poseidon2 indexed Merkle tree, empty leaf = 0 (zkip_lite::null_insert)."""

    def __init__(self, leaves):
        self.leaves = [[int(v) for v in l] for l in leaves]
        self.zeros = [0]
        for _ in range(NULL_DEPTH):
            self.zeros.append(p2.hash2(self.zeros[-1], self.zeros[-1]))

    def _levels(self):
        level = [p2.hash3(*l) for l in self.leaves]
        levels = [level]
        for i in range(NULL_DEPTH):
            if len(level) % 2:
                level = level + [self.zeros[i]]
            level = [p2.hash2(level[2 * k], level[2 * k + 1]) for k in range(len(level) // 2)]
            levels.append(level)
        return levels

    def root(self):
        return self._levels()[NULL_DEPTH][0]

    def path(self, index):
        levels = self._levels()
        out = []
        for i in range(NULL_DEPTH):
            j = (index >> i) ^ 1
            out.append(levels[i][j] if j < len(levels[i]) else self.zeros[i])
        return out

    def insert(self, key):
        low_index = max((i for i, l in enumerate(self.leaves) if l[0] < key), key=lambda i: self.leaves[i][0])
        low = list(self.leaves[low_index])
        low_path = self.path(low_index)
        n = len(self.leaves)
        self.leaves[low_index] = [low[0], n, key]
        new_path = self.path(n)
        self.leaves.append([key, low[1], low[2]])
        return low, low_index, low_path, new_path


class State:
    def __init__(self, data=None):
        data = data or {"bal_asset": [0] * MAX_ASSETS, "bal_amount": [0] * MAX_ASSETS, "null_leaves": [[0, 0, 0]]}
        self.asset = [int(x) for x in data["bal_asset"]]
        self.amount = [int(x) for x in data["bal_amount"]]
        self.null = NullTree(data["null_leaves"])

    @staticmethod
    def load(path):
        return State(None if path == "-" else json.loads(Path(path).read_text()))

    def save(self, path):
        Path(path).write_text(json.dumps({"bal_asset": [str(x) for x in self.asset],
                                          "bal_amount": [str(x) for x in self.amount],
                                          "null_leaves": [[str(v) for v in l] for l in self.null.leaves]}))

    def root(self):
        return p2.hash_many([1] + self.asset + self.amount + [self.null.root(), len(self.null.leaves)])

    def toml(self):
        return ["bal_asset = " + arr([q(x) for x in self.asset]),
                "bal_amount = " + arr([q(x) for x in self.amount]),
                "null_root = " + q(self.null.root()),
                "null_size = " + q(len(self.null.leaves))]

    def apply(self, asset, amount, credit):
        """Mirrors zkip_lite::apply_delta; returns the slot the circuit must be told."""
        slot = self.asset.index(asset) if asset in self.asset else self.asset.index(0)
        self.asset[slot] = asset
        self.amount[slot] = (self.amount[slot] + amount) if credit else (self.amount[slot] - amount)
        return slot


# --------------------------------------------------------------------------------------- legs

def open_leg(bundle, pre, leg):
    """Python mirror of zkip_lite::open_leg, used to derive slots and public commit values."""
    h = [word(pre, 0xE0), word(pre, 0x100)]
    src = [int.from_bytes(word(pre, 0x140), "big"), int.from_bytes(word(pre, 0x160), "big")]
    flow = keccak256(pre)
    cv = [keccak256(TAG + bytes(28) + flow + h[j]) for j in range(2)]
    return {
        "cv": cv, "src": src, "own_cv": cv[leg],
        "asset": field(word(bundle, 0x244)), "amount": int.from_bytes(word(bundle, 0x304), "big"),
        "origin": int.from_bytes(word(bundle, 0x365), "big"),
        "bh_ok": keccak256(bundle) == h[leg],
    }


def commit_state(state, out_state, toml, kind, size, out_dir, w):
    name = "%s_%d" % (kind, size)
    prover = "Prover_" + Path(out_dir).name
    (CIRCUITS / name / (prover + ".toml")).write_text("\n".join(toml) + "\n")
    run([NARGO, "execute", "--prover-name", prover, Path(out_dir).name], cwd=CIRCUITS / name)
    witness = CIRCUITS / "target" / (Path(out_dir).name + ".gz")
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    _, wall, rss = run([BB, "prove", "-b", CIRCUITS / "target" / (name + ".json"), "-w", witness, "-k",
                        VK_DIR / name / "vk", "-o", out_dir, "-t", "evm", "-c", CRS], timed=True)
    record({"circuit": name, "prove_s": round(wall, 2),
            "peak_rss_mb": round(rss / 2 ** 20) if rss else None,
            "proof_bytes": (Path(out_dir) / "proof").stat().st_size, **w})
    state.save(out_state)
    print("0x%064x" % state.root())


def record(entry):
    with open(METRICS, "a") as f:
        f.write(json.dumps({"threads": THREADS, **entry}) + "\n")


def debit(size, w, state, out_state, out_dir):
    chain_id, n = int(w["chain_id"]), int(w["num_legs"])
    bundles = [b32(x) for x in w["bundles"]]
    pres = [b32(x) for x in w["preimages"]]
    legs = [int(x) for x in w["leg_index"]]
    while len(bundles) < size:  # unused slots carry a copy of leg 0 (their checks are switched off)
        bundles.append(bundles[0]), pres.append(pres[0]), legs.append(legs[0])
    prev = state.root()
    lock_asset, lock_amount = b32(w["lock_asset"]), int(w["lock_amount"])
    lock_slot = state.apply(field(lock_asset), lock_amount, True) if lock_amount else 0
    cv_hi, cv_lo, slots = [], [], []
    for k in range(size):
        o = open_leg(bundles[k], pres[k], legs[k])
        if k < n:
            h, l = hi_lo(o["own_cv"])
            cv_hi.append(h), cv_lo.append(l)
            slots.append(state.apply(o["asset"], o["amount"], False) if o["origin"] != chain_id else 0)
        else:
            cv_hi.append(0), cv_lo.append(0), slots.append(0)
    lh, ll = hi_lo(lock_asset)
    toml = ["chain_id = " + q(chain_id), "l1_chain_id = " + q(int(w["l1_chain_id"])),
            "prev_state_root = " + q(prev), "new_state_root = " + q(state.root()), "num_legs = %d" % n,
            "cv_hi = " + arr([q(x) for x in cv_hi]), "cv_lo = " + arr([q(x) for x in cv_lo]),
            "lock_asset_hi = " + q(lh), "lock_asset_lo = " + q(ll), "lock_amount = " + q(lock_amount)]
    toml += state.toml_prev
    toml += ["bundles = " + arr([toml_bytes(b) for b in bundles]), "preimages = " + arr([toml_bytes(b) for b in pres]),
             "leg_index = " + arr(["true" if x else "false" for x in legs]), "slots = " + arr([str(s) for s in slots]),
             "lock_slot = %d" % lock_slot]
    return toml


def claim(size, w, state, out_state, out_dir):
    chain_id, n = int(w["chain_id"]), int(w["num_credits"])
    prev = state.root()
    per = {k: [] for k in ["bundles", "preimages", "credit_leg", "slots", "imt_next_index", "imt_next_value",
                           "imt_index", "imt_height", "imt_path", "cbr_begin", "cbr_left", "batch_number", "batch_ts",
                           "chain_height", "chain_path", "shared_index", "shared_height", "shared_path", "anchor_sel",
                           "null_low", "null_low_index", "null_low_path", "null_new_path"]}
    for c in range(size):
        src_c = min(c, n - 1)  # unused slots repeat credit 0 (their checks are switched off)
        g = lambda key, j=None: w["%s_c%d" % (key, src_c) + ("_l%d" % j if j is not None else "")]
        bundle, pre, leg = b32(g("bundle")), b32(g("preimage")), int(g("credit_leg"))
        o = open_leg(bundle, pre, leg)
        per["bundles"].append(toml_bytes(bundle)), per["preimages"].append(toml_bytes(pre))
        per["credit_leg"].append("true" if leg else "false")
        for key in ("imt_next_index", "imt_next_value", "cbr_begin", "cbr_left"):
            per[key].append(arr([toml_lanes(b32(g(key, j))) for j in range(2)]))
        for key in ("imt_index", "batch_number", "shared_index"):
            per[key].append(arr([q(int(g(key, j))) for j in range(2)]))
        for key in ("imt_height", "batch_ts", "chain_height", "shared_height", "anchor_sel"):
            per[key].append(arr([str(int(g(key, j))) for j in range(2)]))
        for key, depth in (("imt_path", D_IMT), ("chain_path", D_CHAIN), ("shared_path", D_SHARED)):
            per[key].append(arr([arr([toml_lanes(x) for x in pad_path(g(key, j), depth)]) for j in range(2)]))
        if c < n:
            low, low_index, low_path, new_path = state.null.insert(field(o["own_cv"]))
            per["slots"].append(str(state.apply(o["asset"], o["amount"], True) if o["origin"] != chain_id else 0))
        else:
            low, low_index, low_path, new_path = [0, 0, 0], 0, [0] * NULL_DEPTH, [0] * NULL_DEPTH
            per["slots"].append("0")
        per["null_low"].append(arr([q(x) for x in low])), per["null_low_index"].append(q(low_index))
        per["null_low_path"].append(arr([q(x) for x in low_path])), per["null_new_path"].append(arr([q(x) for x in new_path]))
    unlock_asset, unlock_amount = b32(w["unlock_asset"]), int(w["unlock_amount"])
    unlock_slot = state.apply(field(unlock_asset), unlock_amount, False) if unlock_amount else 0
    anchors = [b32(x) for x in w["anchor_roots"]]
    uh, ul = hi_lo(unlock_asset)
    toml = ["chain_id = " + q(chain_id), "l1_chain_id = " + q(int(w["l1_chain_id"])),
            "prev_state_root = " + q(prev), "new_state_root = " + q(state.root()), "num_credits = %d" % n,
            "anchor_hi = " + arr([q(hi_lo(a)[0]) for a in anchors]), "anchor_lo = " + arr([q(hi_lo(a)[1]) for a in anchors]),
            "zkip_chains = " + arr([q(int(x)) for x in w["zkip_chains"]]),
            "unlock_asset_hi = " + q(uh), "unlock_asset_lo = " + q(ul), "unlock_amount = " + q(unlock_amount)]
    toml += state.toml_prev
    toml += ["unlock_slot = %d" % unlock_slot] + ["%s = %s" % (k, arr(v)) for k, v in per.items()]
    return toml


def setup():
    run([NARGO, "compile", "--workspace"], cwd=CIRCUITS)
    VERIFIERS.mkdir(parents=True, exist_ok=True)
    for name in CIRCUIT_NAMES:
        out = VK_DIR / name
        out.mkdir(parents=True, exist_ok=True)
        run([BB, "write_vk", "-b", CIRCUITS / "target" / (name + ".json"), "-o", out, "-t", "evm", "-c", CRS])
        sol = VERIFIERS / (name.title().replace("_", "") + "Verifier.sol")
        run([BB, "write_solidity_verifier", "-k", out / "vk", "-o", sol, "-t", "evm", "--optimized", "-c", CRS])
        log("wrote", sol)


def main():
    cmd = sys.argv[1]
    if cmd == "setup":
        return setup()
    if cmd == "init-root":
        print("0x%064x" % State().root())
        return
    size, w = int(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text())
    state_in, state_out, out_dir = sys.argv[4], sys.argv[5], sys.argv[6]
    state = State.load(state_in)
    state.toml_prev = state.toml()
    toml = (debit if cmd == "debit" else claim)(size, w, state, state_out, out_dir)
    commit_state(state, state_out, toml, cmd, size, out_dir, {"kind": cmd})


if __name__ == "__main__":
    main()
