# yarn ts-node scripts/fetch-chain-creation-params.ts \
#     --bridgehub 0x303a465B659cBB0ab36eE643eA362c509EEb5213 \
#     --era-chain-id 324 \
#     --l1-rpc https://gateway.tenderly.co/public/mainnet \
#     --l1-most-recent-block 23582103 \
#     --gateway-rpc $GATEWAY_MAINNET \
#     --gw-set-chain-creation-params-tx 0x9a25f5852d3e9c1be6b59978f518b73b97e5f91b1e1faa2a8678c683d0cc3410 \
#     --output ./chain-creation-params.toml


yarn ts-node scripts/fetch-chain-creation-params.ts \
    --bridgehub 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE \
    --era-chain-id 270 \
    --l1-rpc https://gateway.tenderly.co/public/sepolia \
    --gateway-rpc $GATEWAY_STAGE \
    --output ./chain-creation-params.toml
