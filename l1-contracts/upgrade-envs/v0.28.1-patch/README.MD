works: 

to deploy factory deps on GW, needs to be run manually for each contract.

forge clean
yarn build:foundry

cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/L1VerifierFflonk.sol/L1VerifierFflonk.json | tr -d '"') -r https://rpc.era-gateway-stage.zksync.dev --private-key ${PRIVATE_KEY?}

cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/L1VerifierPlonk.sol/L1VerifierPlonk.json | tr -d '"') -r https://rpc.era-gateway-stage.zksync.dev --private-key ${PRIVATE_KEY?}

cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/TestnetVerifier.sol/TestnetVerifier.json | tr -d '"') -r https://rpc.era-gateway-stage.zksync.dev --private-key ${PRIVATE_KEY?}

deploy GW contracts: 

V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "deployGWContracts()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1_GW.s.sol:EcosystemUpgrade_v28_1_GW --ffi --rpc-url ${SEPOLIA_GATEWAY_STAGE?} --zksync --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation

after this need to put verifier address in stage.toml or equivalent.

To run main calldata: 

 V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url ${SEPOLIA?}  --gas-limit 20000000000 --private-key ${PRIVATE_KEY?}  --broadcast --slow --skip-simulation

 forge verify-contract 0x73De647A5C0F9716C9D9bA31eFb3Ec93ab52EC7f L1VerifierFflonk --chain {SEPOLIA?} --etherscan-api-key 7PSZZ1PB7WGUHQ5JI51QXI1JIK3REFTVTT

 UPGRADE_ECOSYSTEM_OUTPUT=script-out/v28.1-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade_v28_1.s.sol/11155111/run-latest.json YAML_OUTPUT_FILE=script-out/v28.1-stage-output.yaml yarn upgrade-yaml-output-generator

Still needs fixing: 

forge verify-contract --zksync 0xb742F4d52F6A5e98F11EAc60A7f75Acee534B831 L1VerifierPlonk --verifier zksync  --verifier-url=https://rpc-explorer-verify.era-gateway-stage.zksync.dev/contract_verification