"""Host input rejection and the authenticated tree codec (no proving required)."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import recursive_aggregation as aggregation
from chain_registry import ChainRegistry, DEPTH, LEAF_TAG, ZEROS
import poseidon2 as p2


class TreeTests(unittest.TestCase):
    def test_ragged_independent_subtrees(self):
        leaves = [bytes([i]) * 32 for i in range(1, 18)]
        # One chain's five statements, four chains' three each. Different heights compose.
        shape = bytes([4, 1, 0, 0, 128, 3, 3, 3, 128, 3, 0, 0, 0, 128, 0, 0, 128])
        root, height = aggregation.tree_root(leaves, shape)
        self.assertEqual(height, 3)
        self.assertNotEqual(root, aggregation.tree_root(leaves[::-1], shape)[0])
        for bad in (bytes([127]), bytes([4]), shape + bytes([0]), bytes([128])):
            with self.subTest(shape=bad), self.assertRaises(ValueError):
                aggregation.tree_root(leaves, bad)

    def test_base_fold_domains_are_distinct(self):
        children = [bytes(32)] * aggregation.ARITY
        self.assertNotEqual(aggregation.hash_node(children, True), aggregation.hash_node(children, False))

    def test_metadata_schema_is_rejected_before_native_verify(self):
        for invalid in ([], None, {}, {"circuit": "agg_leaf", "statements": None}):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                Path(directory, "node.json").write_text(json.dumps(invalid))
                with patch.object(aggregation, "native_valid") as verify, self.assertRaises(ValueError):
                    aggregation.load_node(None, directory, [1, 2])
                verify.assert_not_called()

    def test_raw_slots_do_not_accept_recursive_nodes(self):
        class Bridge:
            AGG_INNER = ["debit_1", "debit_4", "claim_1", "claim_2"]
            @staticmethod
            def vk_commit(_): return 1
            @staticmethod
            def log(*_): pass
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            manifest.write_text(json.dumps({"slots": [{"circuit": "agg_leaf", "dir": directory}]}))
            with patch.object(aggregation, "native_valid") as verify, self.assertRaisesRegex(SystemExit, "no valid proof"):
                aggregation.run(Bridge, manifest, Path(directory, "out"))
            verify.assert_not_called()

    def test_admission_exact_capacity(self):
        with patch("chain_registry.DEPTH", 2):
            self.assertEqual(len(ChainRegistry([1, 2, 3, 4]).chains), 4)
            with self.assertRaises(ValueError): ChainRegistry([1, 2, 3, 4, 5])

    def test_admission_paths_beyond_four_chains(self):
        chains = list(range(270270, 270277))
        registry = ChainRegistry(chains)
        self.assertNotEqual(registry.root, ZEROS[DEPTH])
        for chain in chains:
            index, path = registry.membership(chain)
            node = p2.hash3(LEAF_TAG, chain, 0)
            for level, sibling in enumerate(path):
                node = p2.hash2(sibling, node) if (index >> level) & 1 else p2.hash2(node, sibling)
            self.assertEqual(node, registry.root)
        with self.assertRaises(ValueError):
            registry.membership(100)
        for invalid in ([1, 1], [p2.P], [-1]):
            with self.subTest(chains=invalid), self.assertRaises(ValueError): ChainRegistry(invalid)


if __name__ == "__main__":
    unittest.main()
