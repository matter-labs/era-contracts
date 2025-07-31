works: 

to deploy factory deps on GW, needs to be run manually for each contract.

cast send 0x0000000000000000000000000000000000020002 --zk-factory-deps $(yq '.bytecode.object' ./zkout/DefaultUpgrade.sol/DefaultUpgrade.json | tr -d '"') -r https://rpc.era-gateway-stage.zksync.dev --private-key $PRIVATE_KEY

deploy GW contracts: 

V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "deployGWContracts()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1_GW.s.sol:EcosystemUpgrade_v28_1_GW --ffi --rpc-url $SEPOLIA_GATEWAY_STAGE --zksync --gas-limit 20000000000 --private-key $PRIVATE_KEY  --broadcast --slow --skip-simulation

after this need to put verifier address in stage.toml or equivalent.

To run main calldata: 

 V28_1_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.1-patch/stage.toml V28_1_UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28.1-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/EcosystemUpgrade_v28_1.s.sol:EcosystemUpgrade_v28_1 --ffi --rpc-url $SEPOLIA  --gas-limit 20000000000 --private-key $PRIVATE_KEY  --broadcast --slow --skip-simulation

 forge verify-contract 0x73De647A5C0F9716C9D9bA31eFb3Ec93ab52EC7f L1VerifierFflonk --chain sepolia --etherscan-api-key 7PSZZ1PB7WGUHQ5JI51QXI1JIK3REFTVTT

Still needs fixing: 

forge verify-contract 0xBd0a60D20D49Ad957D9B57BA06A3D4F00426DCE0 L1VerifierFflonk --verifier=zksync --verifier-url https://explorer.era-gateway-stage.zksync.dev --zksync -r $SEPOLIA_GATEWAY_STAGE 