works: 

to deploy factory deps on GW, needs to be run manually for each contract.

## Gateway

First, build the contracts:

```shell
forge clean
yarn build:foundry
```

```shell
# For stage
export GATEWAY_RPC=https://rpc.era-gateway-stage.zksync.dev
# For testnet
export GATEWAY_RPC=https://rpc.era-gateway-testnet.zksync.dev/

# For mainnet
export GATEWAY_RPC=https://rpc.era-gateway-mainnet.zksync.dev/

# This private key must have ZK tokens on respective network
export PRIVATE_KEY=XXX
```

Then deploy the bytecodes (you might have to be whitelisted in sequencer in order for this step to succeed):

You also need zksync-foundry version of cast.

**WARNING** - currently we are pushign L1 Verifier not L2 verifier.

```shell
cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/DefaultUpgrade.sol/DefaultUpgrade.json | tr -d '"') -r ${GATEWAY_RPC?} --private-key ${PRIVATE_KEY?}
cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/L1VerifierPlonk.sol/L1VerifierPlonk.json | tr -d '"') -r ${GATEWAY_RPC?} --private-key ${PRIVATE_KEY?}
cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/L1VerifierFFlonk.sol/L1VerifierFflonk.json | tr -d '"') -r ${GATEWAY_RPC?} --private-key ${PRIVATE_KEY?}
cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/TestnetVerifier.sol/TestnetVerifier.json | tr -d '"') -r ${GATEWAY_RPC?} --private-key ${PRIVATE_KEY?}
cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/DualVerifier.sol/DualVerifier.json | tr -d '"') -r ${GATEWAY_RPC?} --private-key ${PRIVATE_KEY?}
```

deploy GW contracts: 

```shell
forge script --sig "deployGWContracts()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1_GW.s.sol:EcosystemUpgrade_v28_1_GW --ffi --rpc-url ${GATEWAY_RPC?} --zksync --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation
```

If you get error starting with `0x3e5efef9` - this means UnknownCodeHash - and you didn't push the stuff correctly before.

**Production**
* don't push bytecodes for TestnetVerifier
* remember to update EcosystemUpgrade_v28_1_GW.s.sol to turn off testnet verifier
* set gas to 20'000'000


Now copy the logs - and put them in output/ENV directory.
They will look like:

```
  VerifierFflonk has been deployed at 0x3CFB3a80Af42cBE4d82C14301690A62D53e870a5
  forge verify-contract 0x3CFB3a80Af42cBE4d82C14301690A62D53e870a5 VerifierFflonk --verifier zksync
  VerifierPlonk has been deployed at 0x92A9Fd0E84354213D9c3d33128eDd6Ea55ee0717
  forge verify-contract 0x92A9Fd0E84354213D9c3d33128eDd6Ea55ee0717 VerifierPlonk --verifier zksync
  Verifier has been deployed at 0xFd5b270Ee63DBDee8e0053731F5d832dE383Ed19
  forge verify-contract 0xFd5b270Ee63DBDee8e0053731F5d832dE383Ed19 Verifier --constructor-args 0x0000000000000000000000003cfb3a80af42cbe4d82c14301690a62d53e870a500000000000000000000000092a9fd0e84354213d9c3d33128edd6ea55ee0717 --verifier zksync
```

### Contract verification

Please run (and adjust the address & rpc):

```shell
export CONTRACT_VERIFIER_URL=https://rpc-explorer-verify.era-gateway-testnet.zksync.dev/contract_verification

forge verify-contract 0x3CFB3a80Af42cBE4d82C14301690A62D53e870a5 L1VerifierFflonk --verifier zksync --zksync --verifier-url ${CONTRACT_VERIFIER_URL?}
forge verify-contract 0x92A9Fd0E84354213D9c3d33128eDd6Ea55ee0717 L1VerifierPlonk --verifier zksync --zksync --verifier-url ${CONTRACT_VERIFIER_URL?}
forge verify-contract 0xFd5b270Ee63DBDee8e0053731F5d832dE383Ed19 TestnetVerifier --verifier zksync --constructor-args 0x0000000000000000000000003cfb3a80af42cbe4d82c14301690a62d53e870a500000000000000000000000092a9fd0e84354213d9c3d33128edd6ea55ee0717 --zksync --verifier-url ${CONTRACT_VERIFIER_URL?}
```

after this need to put verifier address in stage.toml or equivalent.

```shell
export CONTRACT_VERIFIER_URL=https://rpc-explorer-verify.era-gateway-mainnet.zksync.dev/contract_verification
```

## L1

Make sure to run `yarn build:foundry` in l2-contracts directory too.

```shell
export SEPOLIA="https://1rpc.io/sepolia"
export MAINNET="https://eth.drpc.org"

```

To run in stage:
```shell
V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url ${SEPOLIA?}  --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation
```

To run in testnet:
```shell
V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/testnet.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url ${SEPOLIA?}  --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation
```

To run in mainnet:
```shell
V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/mainnet.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url ${MAINNET?}  --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation
```


To run main calldata: 

 V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url ${SEPOLIA?}  --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation

 forge verify-contract 0x73De647A5C0F9716C9D9bA31eFb3Ec93ab52EC7f L1VerifierFflonk --chain {SEPOLIA?} --etherscan-api-key 7PSZZ1PB7WGUHQ5JI51QXI1JIK3REFTVTT

 UPGRADE_ECOSYSTEM_OUTPUT=script-out/v28.1-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade_v28_1.s.sol/11155111/run-latest.json YAML_OUTPUT_FILE=script-out/v28.1-stage-output.yaml yarn upgrade-yaml-output-generator

Still needs fixing: 

forge verify-contract --zksync 0xb742F4d52F6A5e98F11EAc60A7f75Acee534B831 L1VerifierPlonk --verifier zksync  --verifier-url=https://rpc-explorer-verify.era-gateway-stage.zksync.dev/contract_verification