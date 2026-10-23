"""Composable proof trees. Nodes need no underlying proof files when another aggregator consumes them."""

import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from keccak import keccak256

ARITY = 4
NODE_INPUTS = 6
MAX_HEIGHT = 30
FOLD_TOKEN = 128
BASE_DOMAIN = keccak256(b"zkSync:ZKIP:aggregationBase:v1")
FOLD_DOMAIN = keccak256(b"zkSync:ZKIP:aggregationFold:v1")


def hash_node(children, base):
    assert len(children) == ARITY
    return keccak256((BASE_DOMAIN if base else FOLD_DOMAIN) + b"".join(children))


def tree_root(digests, shape):
    stack, cursor = [], 0
    for token in shape:
        if token == 0:
            stack.append((bytes(32), 0))
        elif token <= ARITY:
            if cursor + token > len(digests):
                raise ValueError("incomplete statement metadata")
            children = digests[cursor:cursor + token] + [bytes(32)] * (ARITY - token)
            cursor += token
            stack.append((hash_node(children, True), 0))
        elif token == FOLD_TOKEN and len(stack) >= ARITY:
            children, stack = stack[-ARITY:], stack[:-ARITY]
            height = max(child[1] for child in children) + 1
            if height > MAX_HEIGHT:
                raise ValueError("aggregation height")
            stack.append((hash_node([c[0] for c in children], False), height))
        else:
            raise ValueError("invalid aggregation shape")
    if len(stack) != 1 or cursor != len(digests):
        raise ValueError("invalid aggregation metadata")
    return stack[0]


@dataclass
class Node:
    directory: Path
    circuit: str
    inputs: list
    digests: list
    commitments: list
    statements: list
    shape: bytes

    @property
    def count(self):
        return self.inputs[2]

    @property
    def height(self):
        return self.inputs[3]


def save_metadata(node):
    root = node.directory
    (root / "statement_digests").write_bytes(b"".join(node.digests))
    (root / "vk_commitments").write_bytes(b"".join(x.to_bytes(32, "big") for x in node.commitments))
    (root / "tree_shape").write_bytes(node.shape)
    (root / "node.json").write_text(json.dumps({"circuit": node.circuit, "statements": node.statements}) + "\n")


def native_valid(bridge, circuit, directory):
    if circuit not in bridge.AGG_INNER + ["agg_leaf", "agg_fold"]:
        return False
    key = bridge.VK_REC_DIR / circuit / "vk"
    command = [str(bridge.BB), "verify", "-k", str(key), "-p", str(directory / "proof"),
               "-i", str(directory / "public_inputs"), "-t", "noir-recursive", "-c", str(bridge.CRS)]
    return subprocess.run(([bridge.WRAPPER] if bridge.WRAPPER else []) + command, capture_output=True).returncode == 0


def load_node(bridge, directory, family):
    directory = Path(directory)
    info = json.loads((directory / "node.json").read_text())
    if not isinstance(info, dict) or not isinstance(info.get("statements"), list):
        raise ValueError("invalid recursive node metadata schema")
    circuit = info.get("circuit")
    if circuit not in ("agg_leaf", "agg_fold") or not native_valid(bridge, circuit, directory):
        raise ValueError("invalid recursive node proof")
    inputs = bridge.fields(directory / "public_inputs")
    if len(inputs) != NODE_INPUTS or inputs[:2] != family or inputs[2] <= 0 or inputs[3] > MAX_HEIGHT:
        raise ValueError("recursive node key family/count")
    raw = (directory / "statement_digests").read_bytes()
    if len(raw) != inputs[2] * 32:
        raise ValueError("recursive node digest count")
    digests = [raw[i:i + 32] for i in range(0, len(raw), 32)]
    commitments = bridge.fields(directory / "vk_commitments")
    shape = (directory / "tree_shape").read_bytes()
    root, height = tree_root(digests, shape)
    if (height != inputs[3] or list(bridge.hi_lo(root)) != inputs[4:] or
            len(commitments) != inputs[2] or len(info["statements"]) != inputs[2]):
        raise ValueError("recursive node metadata is not committed")
    return Node(directory, circuit, inputs, digests, commitments, info["statements"], shape)


def prove_leaf(bridge, slots, directory, family):
    count = len(slots)
    assert 0 < count <= ARITY
    padded = slots + [slots[0]] * (ARITY - count)
    commitments = [bridge.vk_commit(s["circuit"]) for s in slots]
    digests = [b"".join(limb.to_bytes(16, "big") for limb in
                       bridge.statement_digest(vk, bridge.fields(Path(s["dir"]) / "public_inputs")))
               for s, vk in zip(slots, commitments)]
    root = hash_node(digests + [bytes(32)] * (ARITY - count), True)
    inputs = family + [count, 0] + list(bridge.hi_lo(root))
    toml = ["base_vk = " + bridge.q(family[0]), "fold_vk = " + bridge.q(family[1]),
            "statement_count = " + str(count), "height = 0",
            "vks = " + bridge.arr([bridge.arr([bridge.q(x) for x in bridge.fields(bridge.VK_REC_DIR / s["circuit"] / "vk")]) for s in padded]),
            "key_hashes = " + bridge.arr([bridge.q(bridge.fields(bridge.VK_REC_DIR / s["circuit"] / "vk_hash")[0]) for s in padded]),
            "proofs = " + bridge.arr([bridge.arr([bridge.q(x) for x in bridge.fields(Path(s["dir"]) / "proof")]) for s in padded]),
            "slot_pis = " + bridge.arr([bridge.arr([bridge.q(x) for x in bridge.fields(Path(s["dir"]) / "public_inputs")]) for s in padded])]
    bridge.prove_aggregation("agg_leaf", toml, directory, "noir-recursive", inputs, count)
    node = Node(directory, "agg_leaf", inputs, digests, commitments,
                [s.get("settlement", s) for s in slots], bytes([count]))
    save_metadata(node)
    return node


def prove_fold(bridge, children, directory, family):
    count = sum(child.count for child in children)
    height = max(child.height for child in children) + 1
    if height > MAX_HEIGHT:
        raise ValueError("aggregation height")
    padded = children + [children[0]] * (ARITY - len(children))
    roots = [b"".join(x.to_bytes(16, "big") for x in child.inputs[4:]) for child in children]
    root = hash_node(roots + [bytes(32)] * (ARITY - len(children)), False)
    inputs = family + [count, height] + list(bridge.hi_lo(root))
    toml = ["base_vk = " + bridge.q(family[0]), "fold_vk = " + bridge.q(family[1]),
            "statement_count = " + str(count), "height = " + str(height), "active_children = " + str(len(children)),
            "vks = " + bridge.arr([bridge.arr([bridge.q(x) for x in bridge.fields(bridge.VK_REC_DIR / n.circuit / "vk")]) for n in padded]),
            "key_hashes = " + bridge.arr([bridge.q(bridge.fields(bridge.VK_REC_DIR / n.circuit / "vk_hash")[0]) for n in padded]),
            "proofs = " + bridge.arr([bridge.arr([bridge.q(x) for x in bridge.fields(n.directory / "proof")]) for n in padded]),
            "child_pis = " + bridge.arr([bridge.arr([bridge.q(x) for x in n.inputs]) for n in padded])]
    bridge.prove_aggregation("agg_fold", toml, directory, "noir-recursive", inputs, count)
    node = Node(directory, "agg_fold", inputs, [d for n in children for d in n.digests],
                [v for n in children for v in n.commitments], [s for n in children for s in n.statements],
                b"".join(n.shape for n in children) + bytes(ARITY - len(children)) + bytes([FOLD_TOKEN]))
    save_metadata(node)
    return node


def run(bridge, manifest, out_dir, finalize=True):
    started = time.monotonic()
    request = json.loads(Path(manifest).read_text())
    out_dir = Path(out_dir)
    family = [bridge.vk_commit("agg_leaf"), bridge.vk_commit("agg_fold")]
    included, nodes = [], []
    if "nodes" in request:
        for record in request["nodes"]:
            try:
                node = load_node(bridge, record["dir"], family)
            except (ValueError, OSError, KeyError) as error:
                bridge.log("aggregator: dropped node", record["dir"], str(error))
                included.append(False)
                continue
            included.append(True)
            nodes.append(node)
    else:
        slots = request["slots"]
        valid = []
        for slot in slots:
            ok = slot["circuit"] in bridge.AGG_INNER and native_valid(bridge, slot["circuit"], Path(slot["dir"]))
            included.append(ok)
            if ok:
                valid.append(slot)
            else:
                bridge.log("aggregator: dropped", slot["dir"], "(native verification failed)")
        for offset in range(0, len(valid), ARITY):
            directory = out_dir / "nodes" / (out_dir.name + "_leaf_" + str(offset // ARITY))
            nodes.append(prove_leaf(bridge, valid[offset:offset + ARITY], directory, family))
    if not nodes:
        raise SystemExit("aggregator: no valid proof to aggregate")
    level = 0
    while len(nodes) > 1:
        next_nodes = []
        for offset in range(0, len(nodes), ARITY):
            directory = out_dir / "nodes" / (out_dir.name + "_fold_" + str(level) + "_" + str(offset // ARITY))
            next_nodes.append(prove_fold(bridge, nodes[offset:offset + ARITY], directory, family))
        nodes, level = next_nodes, level + 1
    root = nodes[0]
    if finalize:
        toml = ["base_vk = " + bridge.q(family[0]), "fold_vk = " + bridge.q(family[1]),
                "statement_count = " + str(root.count), "height = " + str(root.height),
                "vk = " + bridge.arr([bridge.q(x) for x in bridge.fields(bridge.VK_REC_DIR / root.circuit / "vk")]),
                "key_hash = " + bridge.q(bridge.fields(bridge.VK_REC_DIR / root.circuit / "vk_hash")[0]),
                "proof = " + bridge.arr([bridge.q(x) for x in bridge.fields(root.directory / "proof")]),
                "node_pis = " + bridge.arr([bridge.q(x) for x in root.inputs])]
        bridge.prove_aggregation("agg_finalize", toml, out_dir, "evm", root.inputs, root.count)
        root = Node(out_dir, "agg_finalize", root.inputs, root.digests, root.commitments, root.statements, root.shape)
        save_metadata(root)
    else:
        out_dir.mkdir(parents=True, exist_ok=True)
        for name in ("proof", "public_inputs"):
            (out_dir / name).write_bytes((root.directory / name).read_bytes())
        root = Node(out_dir, root.circuit, root.inputs, root.digests, root.commitments, root.statements, root.shape)
        save_metadata(root)
    bridge.record({"kind": "recursive_request", "tag": out_dir.name, "finalize": finalize,
                   "real_slots": root.count, "height": root.height, "wall_s": round(time.monotonic() - started, 2)})
    print("0x" + "".join("01" if ok else "00" for ok in included))
