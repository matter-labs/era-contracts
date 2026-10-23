import os
import subprocess
import unittest
from unittest.mock import patch

import tomli

import benchmark as bench


def toml_value(value):
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(x) for x in value) + "]"
    if isinstance(value, str):
        return '"' + value + '"'
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


class FixtureTests(unittest.TestCase):
    def test_empty_slot_is_distinct_from_sentinel_leaf(self):
        expected = bytes.fromhex("07a2eee29e5f66808854f031930e2c720a817e17f9ac7083092ef9c1fc8acf39")
        for variant in bench.VARIANTS:
            tree = bench.Imt(variant)
            self.assertEqual(tree.zeros[0], expected)
            self.assertNotEqual(tree.root(), tree.zeros[0])

    def test_compact_format_preserves_accounting_and_nonce(self):
        for variant in bench.VARIANTS:
            with self.subTest(variant=variant):
                f = bench.flow(variant, 1)
                opened = bench.opened(variant, f["bundle"], f["pre"], f["leg"])
                self.assertEqual(opened["amount"], 10)
                self.assertEqual(opened["origin"], bench.L1)
                self.assertEqual(opened["asset"], bench.reference.field(bench.asset_id()))
                self.assertEqual(opened["own_cv"], f["cvs"][f["leg"]])
                self.assertNotEqual(f["cvs"], bench.flow(variant, 2)["cvs"])
                self.assertEqual(len(f["bundle"]), bench.TRANSFER_BYTES if variant.startswith("compact_") else bench.LEGACY_BUNDLE_BYTES)

    def test_balance_changes_and_consumed_set(self):
        for variant in bench.VARIANTS:
            for name in bench.CIRCUITS:
                with self.subTest(variant=variant, circuit=name):
                    _, state = bench.witness(variant, name)
                    self.assertEqual(state.asset[0], bench.reference.field(bench.asset_id()))
                    self.assertEqual(state.amount, [0] * bench.reference.MAX_ASSETS)
                    expected_size = int(name[-1]) + 1 if name.startswith("claim") else 1
                    self.assertEqual(len(state.null.leaves), expected_size)

    def test_imt_insertion_paths_cover_growth_and_predecessor_updates(self):
        for variant in bench.VARIANTS:
            tree = bench.Imt(variant)
            for value in (50, 10, 90, 30, 70, 20, 80, 40, 60):
                with self.subTest(variant=variant, value=value):
                    before, count = tree.root(), len(tree.leaves)
                    proof = tree.insert(value)
                    old_leaf = bench.protocol_hash(variant, proof["insert_low_value"] + proof["insert_low_next_index"] + proof["insert_low_next_value"])
                    self.assertEqual(bench.path_root(variant, old_leaf, proof["insert_low_index"], proof["insert_low_path"], (count - 1).bit_length()), before)
                    new_leaf = bench.protocol_hash(variant, bench.word(value) + proof["insert_low_next_index"] + proof["insert_low_next_value"])
                    self.assertEqual(bench.path_root(variant, new_leaf, count, proof["insert_new_path"], count.bit_length()), tree.root())
            with self.assertRaises(ValueError):
                tree.insert(50)


@unittest.skipUnless(os.environ.get("NARGO"), "Set NARGO to run circuit regression tests")
class CircuitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.variant = "compact_blake3"
        cls.root = bench.generate(cls.variant, bench.CIRCUITS)
        subprocess.run([os.environ["NARGO"], "compile", "--workspace"], cwd=cls.root, check=True, capture_output=True)

    def execute(self, circuit, data=None, expected_error=None):
        if data is None:
            text, _ = bench.witness(self.variant, circuit)
        else:
            text = "\n".join(k + " = " + toml_value(v) for k, v in data.items()) + "\n"
        package = self.root / circuit
        (package / "Regression.toml").write_text(text)
        result = subprocess.run([os.environ["NARGO"], "execute", "--prover-name", "Regression", "regression"],
                                cwd=package, capture_output=True, text=True)
        if expected_error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def data(self, circuit):
        return tomli.loads(bench.witness(self.variant, circuit)[0])

    def test_valid_debits_and_claims(self):
        for circuit in bench.CIRCUITS:
            with self.subTest(circuit=circuit):
                self.execute(circuit)

    def test_omitted_outgoing_leg(self):
        data = self.data("debit_4")
        data["num_legs"] = 3
        self.execute("debit_4", data, "IMT end root")

    def test_invalid_predecessor_index(self):
        data = self.data("debit_1")
        data["insert_low_index"][0] = data["leaf_count"]
        self.execute("debit_1", data, "IMT low index")

    def test_wrong_leaf_count(self):
        data = self.data("debit_1")
        data["leaf_count"] = 2
        self.execute("debit_1", data, "IMT predecessor root")

    def test_tampered_predecessor_path(self):
        data = self.data("debit_4")
        data["insert_low_path"][1][0][0] = "0x1"
        self.execute("debit_4", data, "IMT predecessor root")

    def test_tampered_append_path(self):
        data = self.data("debit_1")
        data["insert_new_path"][0][0][0] = "0x1"
        self.execute("debit_1", data, "IMT append slot")

    def test_duplicate_imt_value(self):
        data = self.data("debit_1")
        cv = bench.flow(self.variant, 1)["cvs"][bench.flow(self.variant, 1)["leg"]]
        data["insert_low_next_value"][0] = [hex(x) for x in bench.reference.lanes(cv)]
        self.execute("debit_1", data, "IMT duplicate or successor order")

    def test_late_counter_leg(self):
        with patch.object(bench, "TIMESTAMP", bench.DEADLINE + 1):
            data = self.data("claim_1")
        self.execute("claim_1", data, "leg settled after the deadline")

    def test_wrong_anchor(self):
        data = self.data("claim_1")
        data["anchor_hi"][0] = hex(int(data["anchor_hi"][0], 16) ^ 1)
        self.execute("claim_1", data, "leg not under the anchor root")

    def test_non_zkip_source(self):
        data = self.data("claim_1")
        from chain_registry import ChainRegistry
        data["chain_registry_root"] = hex(ChainRegistry([bench.B]).root)
        self.execute("claim_1", data, "leg source is not a ZKIP chain")

    def test_admission_path_tampering(self):
        data = self.data("claim_1")
        data["registry_path"][0][0][0] = hex(int(data["registry_path"][0][0][0], 16) ^ 1)
        self.execute("claim_1", data, "leg source is not a ZKIP chain")

    def test_admission_beyond_four_chains(self):
        from chain_registry import ChainRegistry
        data = self.data("claim_1")
        registry = ChainRegistry([1, 2, 3, 4, bench.A, bench.B])
        data["chain_registry_root"] = hex(registry.root)
        data["chain_registry_count"] = len(registry.chains)
        sources = bench.flow(self.variant, 1)["sources"]
        paths = [registry.membership(source) for source in sources]
        data["registry_index"] = [[index for index, _ in paths]]
        data["registry_path"] = [[[hex(x) for x in path] for _, path in paths]]
        self.execute("claim_1", data)

    def test_wrong_destination(self):
        data = self.data("claim_1")
        data["chain_id"] = hex(bench.B + 1)
        self.execute("claim_1", data, "bundle is not to this chain")

    def test_double_credit(self):
        data = self.data("claim_1")
        _, consumed = bench.witness(self.variant, "claim_1")
        data["prev_state_root"] = hex(consumed.root())
        data["bal_asset"] = [hex(x) for x in consumed.asset]
        data["null_root"] = hex(consumed.null.root())
        data["null_size"] = hex(len(consumed.null.leaves))
        self.execute("claim_1", data, "low leaf not in consumed set")

    def test_origin_cannot_bypass_debit(self):
        original = bench.transfer

        def forged(*args, **kwargs):
            bundle = bytearray(original(*args, **kwargs))
            bundle[160:192] = bench.word(bench.A)
            return bytes(bundle)

        with patch.object(bench, "transfer", side_effect=forged):
            data = self.data("debit_1")
        self.execute("debit_1", data, "asset id is not the NTV id")

    def test_field_alias_cannot_change_amount(self):
        original = bench.transfer

        def forged(*args, **kwargs):
            bundle = bytearray(original(*args, **kwargs))
            amount = int.from_bytes(bundle[128:160], "big")
            bundle[128:160] = bench.word(amount + bench.reference.P)
            return bytes(bundle)

        with patch.object(bench, "transfer", side_effect=forged):
            data = self.data("debit_1")
        self.execute("debit_1", data, "noncanonical transfer integer")


if __name__ == "__main__":
    unittest.main()
