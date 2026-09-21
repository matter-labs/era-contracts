# Preserving operator hooks with zksolc 1.5.17

Operator hooks and their parameters are memory writes observed by server tracers,
not by the Yul program. Ordinary dead-store elimination can remove them. The old
`NoInline` value helper alone did not make those stores observable; its name
`unoptimized` had no compiler meaning. Moving the stores into a `NoInline` helper
preserved them but added a frame at the point where the server processes a hook.

This candidate instead inlines the store wrapper and applies LLVM `optnone`
to the existing value helper. That helper returns before the store executes, so
the hook retains its previous frame placement. Validation hooks already emitted
within transaction validation remain nested; not every hook must be at root.

```text
-force-attribute=$llvm_NoInline_llvm$_unoptimized:optnone
```

## Build scope and limitations

The option lives in the normal system-contracts Foundry and Hardhat configuration.
The standalone Yul build also reads that configuration. There is no separate
bootloader compiler or compilation step. The function attribute targets only the
named helper, but LLVM options also affect metadata of other system contracts;
their hashes must be regenerated consistently. L1 EVM compiler settings are
unchanged. Verification must retain `settings.llvmOptions` in Standard JSON input.

The public zksolc option forwards a **hidden LLVM debugging facility**, not a stable
hook API. An unmatched function name silently does nothing. Build-time source
tests reject a missing helper or configuration drift, and runtime tests check emitted hooks, ordering,
parameter writes and frame depth. Compiler-owner approval is required before
adopting this workaround. Revalidate on every compiler change; a dedicated
observable/ordered-store primitive would be a stronger long-term solution.

## Evidence and rollout gates

Isolated experiments used unchanged zksolc 1.5.17, exact candidate system artifacts
(60 matching bytecode hashes), and server commit
`7ede65ea410fd1ca373c9154518e782f53b38d19` without the proposed VM fixes.
All 29 bootloader fixtures and production hook checks passed. Production
`proved_batch` pubdata finalization passed on Legacy VM, FastVM and shadow mode;
the original `NoInline`-store CI bootloader failed those same three control tests.
These are server-library tests, not live-node or prover certification.

Measured production bytecode grows from 72,544 to 77,920 bytes (about 7.4%). Gas
and prover impact remain review gates. A source-only readback alternative also
passed the experiments, but grew to 88,224 bytes and adds read/call/branch work.

This changes bootloader hashes. Regenerate dependent genesis configuration and
upgrade calldata before rollout, then rerun PUVT, bundle handoff, server CI and
simulation. Do not mix the new hashes with the previously published mainnet
candidate. Only after replacement validation should the server frame/log changes
be reverted; compiler installation and contracts-pin changes are independent.
