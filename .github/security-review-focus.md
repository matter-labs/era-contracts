# Contracts Security Review Focus

Applies to ZKsync OS contracts, shared L1 contracts, genesis, deployment and upgrade tooling in this repository.

## Available evidence

- Base the review on the supplied changes and relevant repository code, configuration, tests and documentation.
- Trace changed behavior through relevant callers, validation and state transitions. Check documented invariants against their implementation.
- Separate verified behavior from assumptions. State missing evidence or uncertainty, especially when assessing deployment state, dependencies or compatibility.

## Scope and trust boundaries

- Protect shared escrow, base-token reserves, bridged assets, authenticated messages, settlement correctness and upgrade authority.
- Treat L1 and L2 callers, token contracts, custom asset handlers, message payloads, proof encodings and external tooling inputs as untrusted.
- Governance is trusted to exercise its documented powers correctly. Review initialization, authority handovers and paths that let other actors gain those powers.
- A chain admin, operator or custom asset handler has only its documented authority. Check whether it can affect other chains, unrelated assets or shared infrastructure.
- Distinguish proof-system soundness assumptions from the on-chain checks selecting verifiers, binding public inputs and enforcing interop eligibility and balance caps.
- Trace shared L1 changes through callers and interfaces visible in the checkout. Do not assume which chains use an implementation or which versions are deployed unless the supplied context establishes that fact.
- Follow the changed behavior through production callers and consumers. Tests, fixtures and generated outputs can expose a production bug; their presence is not an exclusion.

## Authorization and identity

- Trace the original caller through routers, forwarded calls, delegate calls and L1-to-L2 address aliasing. Preserve sender, chain and asset identity at every boundary.
- Check asset registration and counterpart authentication. A handler or tracker for one asset must not acquire authority over another asset or a shared vault.
- Check governance, chain admin, validator and system-contract permissions separately, including initialization and ownership changes.
- Trusting governance decisions does not exempt governance implementation from review. Check scheduling, timelocks, cancellation, owner transitions and attached restrictions across new selectors, multicalls and encodings.
- Check commit, prove and execute roles, multisig committer thresholds, global and per-chain execution delays, and the intended priority-mode exceptions. An ordinary caller must not acquire validator authority through these paths.
- Freezing must block the selectors marked freezable while preserving authorized recovery. Check freeze and unfreeze permissions and the freezability of new or replaced facets.
- Privileged ZKsync OS hooks authenticate their immediate fixed-address built-in caller. Check that public entry points cannot misuse that caller to forge messages, mint value, install bytecode or publish interop commitments.
- Permissionless token registration and transaction submission are intentional. Report a concrete authority bypass or impact beyond the caller's permitted actions.

## Funds, messages and replay protection

- Trace lock, burn, mint, release, failed-deposit claims, refunds and fees together. A successful credit must have the backing required by that asset and route.
- Check chain and asset accounting, base-token reserves, interop pools and balance caps. One chain or handler must not spend another's backing outside the documented shared-pool rules.
- Bind message and proof acceptance to the correct source chain, destination, sender, recipient, asset, amount, batch and root. Check domain separation and ambiguous encodings.
- Verify that withdrawal, failed-deposit, bundle, call and refund identifiers cannot be reused across routes or chains. State consumption and external calls must remain safe under reentrancy and partial failure.
- Treat arbitrary tokens and receivers as adversarial. Check balance deltas, callbacks, return data and unusual token behavior when they can affect other users or shared accounting.

## Settlement, proofs and availability

- Trace batch commit, proof verification and execution to the same stored batch and full public-input commitment, including runtime configuration, data availability and priority operations.
- Check verifier selection, proof envelopes, required proof systems, upgrade boundaries and configuration changes with already committed batches. Test-only proof bypasses must stay confined to their intended environments.
- Check authenticated roots, leaf indices, lengths, timestamps and imported-root validation. Reject malformed proofs and cross-domain substitutions rather than relying on an operator to format them correctly.
- Check the bindings and trust assumptions of the configured data-availability scheme, including calldata, blobs and attestations where applicable. Preserve permanent-rollup restrictions on validator pairs and pubdata configuration; do not impose rollup guarantees on an intentional validium mode.
- Bind proven interop fee units to execute-time charging and authorized fee-manager withdrawals. Trace any waiver or exemption through its documented authority.
- Check priority-transaction ordering, inclusion and gas bounds. Publicly submitted transactions must not bypass restrictions or permanently block unrelated progress at low cost.
- Distinguish an operator's accepted ability to delay its own chain from a new way to execute invalid state or disrupt other chains.

## Interop and atomic flows

- Check peer consent, enabled-chain requirements and receive filters on every path where the protocol requires them, including finality and timeout refunds.
- Finality and timeout authorization must remain mutually exclusive for the same flow. Verify authenticated time, inclusion and non-inclusion evidence, and the chain-registration prerequisites for those proofs.
- Distinguish permission to execute from execution itself. Atomic flow authorization does not promise that every destination call succeeds or that arbitrary sender recovery logic returns funds.
- Trace execution, unbundling and refund state transitions together. Check duplicate effects, recovery authorization, value recipients and compatibility with in-flight payloads after upgrades.
- For denial of service, identify attacker prerequisites, cost, affected users and the available recovery. Separate self-inflicted failures from shared queue, proof or settlement failures.

## Upgrades, genesis and operational tooling

- Check source and target releases, transition commitments, proxy identities, facets, implementations, upgrade engines and initialization data as one authority path.
- Compare changed storage declarations and inherited layouts with supplied base snapshots where available. Preserve reserved slots and enum values; check initializer replay, rollback and compatibility with older interfaces represented in the available code and fixtures.
- For components touched by the change, compare genesis and upgrade inventories in both directions: fixed addresses, proxy ownership, implementations, initialization and required state must agree unless a difference is intentional.
- L2 built-ins cannot depend on constructors or immutables. Check that genesis and upgrade initialization establish their required state.
- Check governance bundle ordering, atomicity, authority handovers and postconditions. A valid package hash or published bytecode alone does not establish safe executable behavior.
- Check scheduled activation times and per-version precondition checkers against their documented authority and compatibility with pending upgrades.
- Trace untrusted configuration, RPC data, artifact paths and command arguments in tooling to file writes, subprocesses and transaction generation. Check how code binds output to the network, revision, addresses, bytecode and signers established by local configuration and artifacts.

## Reporting

Report reachable security impact introduced or worsened by the change. State the attacker role, configuration, affected assets or users, and the broken invariant.
Static code tracing can substantiate a finding without executing an exploit. Separate code-proven behavior from deployment assumptions, and do not claim runtime reproduction.
Use existing accepted limitations as context; do not suppress a regression or broader impact because a related limitation was previously documented.
Avoid style, gas-only suggestions and claims that require a trusted role to deliberately misuse its authorized powers.
