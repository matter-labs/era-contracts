UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.29.3-vk-update/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v29-3-ecosystem.toml forge script --sig "run()" ./deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol:VerifierOnlyUpgrade --ffi --rpc-url $TENDERLY_SEPOLIA --gas-limit 20000000000 --private-key $TEST_PK --broadcast


UPGRADE_ECOSYSTEM_OUTPUT=script-out/v29-3-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/VerifierOnlyUpgrade.s.sol/11155111/run-latest.json YAML_OUTPUT_FILE=script-out/yaml-output.yaml yarn upgrade-yaml-output-generator
