# Production divergences observed while hardening EVM-1309

- MockL2MessageVerification accepts synthetic inclusion proofs: 03/06/07/08/09/13 cannot prove settlement authentication or rejection of forged roots; fixable with real root/proof relay.
- MockL1MessengerHook is a no-op: 02/05/07/08/09 can assert L1MessengerZKOS events, but not server-side message publication; needs a server-backed test.
- MockMintBaseTokenHook is a no-op and L2BaseToken is prefunded: 02/05 can prove recipient credits and source debits, but not production mint/supply conservation; needs real mint integration.
- MockContractDeployer bypasses production force deployments: 01 checks the mock runtime, not deployment authorization or proxy installation; fixable with real deployment integration.
- L2 implementations are installed directly at predeploy addresses: 01 runtime identity does not cover proxy delegation, admin slots or upgrades; fixable by deploying production proxies.
- No validium chain: 01/04 and bridging specs cannot exercise DA-mode-specific behavior; fixable with an additional topology (outside this PR).
- One gateway topology with a deliberately restricted registration set: 03 rejects unregistered routes, not every production cross-settlement route; fixable with additional registered topologies.
- L1 withdrawal inclusion uses DummyL1MessageRoot and synthetic proofs: 02/05 finalization assertions cannot prove committed/proved/executed batch inclusion; needs real settlement.
- Priority requests are replayed as funded, impersonated EVM transactions: 02/05 can assert exact l2Value delivery, but not bootloader gas refunds or production pubdata fees; needs a server-backed test.
- Spec 13 imports synthetic settlement roots through bootloader impersonation: IMT proofs and timeout boundaries are checked, but chain-batch leaf authentication is mocked; fixable with authenticated root relay.
- Gateway setup replaces L2ChainAssetHandler with L2ChainAssetHandlerDev (and an L1 Dev handler) to enable migrations disabled in production: 01 must compare the gateway runtime to the Dev artifact; production migration restrictions need separate coverage.
