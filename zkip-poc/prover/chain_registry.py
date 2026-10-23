"""Append-only Poseidon2 admitted-chain tree; membership witnesses stay private."""
import poseidon2 as p2

DEPTH = 32
LEAF_TAG = int.from_bytes(b"zkip:chain:v1", "big")
ZEROS = [0]
for _ in range(DEPTH):
    ZEROS.append(p2.hash2(ZEROS[-1], ZEROS[-1]))


class ChainRegistry:
    def __init__(self, chains):
        self.chains = [int(chain) for chain in chains if int(chain) != 0]
        if len(set(self.chains)) != len(self.chains) or len(self.chains) >= 1 << DEPTH:
            raise ValueError("invalid admitted-chain list")
        if any(not 0 < chain < p2.P for chain in self.chains):
            raise ValueError("chain id is not canonical")
        self.levels = [{i: p2.hash3(LEAF_TAG, chain, 0) for i, chain in enumerate(self.chains)}]
        for level in range(DEPTH):
            previous = self.levels[-1]
            self.levels.append({i: p2.hash2(previous.get(2 * i, ZEROS[level]),
                                          previous.get(2 * i + 1, ZEROS[level]))
                                for i in {index // 2 for index in previous}})
        self.root = self.levels[-1].get(0, ZEROS[DEPTH])

    def membership(self, chain):
        index = self.chains.index(chain)
        return index, [self.levels[level].get((index >> level) ^ 1, ZEROS[level]) for level in range(DEPTH)]
