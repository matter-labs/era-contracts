# Elliptic curve differential tests

This directory contains differential tests for elliptic curve precompiles (EcAdd, EcMul, EcPairing), testing the correctness of the precompiles implementation against the go-ethereum implementation.

Under the hood, pseudo random inputs are generated via a python script (`python/EcHelper.py`) using https://github.com/ethereum/py_pairing and then passed to both the ZKsync precompile and the go-ethereum precompile. The output of both precompiles is then compared.

## Prerequisites

1. Make sure python3 and go are installed
2. Change working directory to `system-contracts`
3. Run local node
   ```bash
   yarn test-node
   ```
4. Add npm script to `package.json`
   ```diff
   + "test:diff": "hardhat test --network zkSyncTestNode",
   ```

## How to run the tests

**EcAdd:**
```bash
yarn test:diff --grep "diff-fuzz\(EcAdd\)"
```

**EcMul:**
```bash
yarn test:diff --grep "diff-fuzz\(EcMul\)"
```

**EcPairing:**
```bash
yarn test:diff --grep "diff-fuzz\(EcPairing\)"
```
