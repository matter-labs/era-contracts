# Validium data availability

`ValidiumL1DAValidator` does not require the batch's reconstruction data to be published on Ethereum.
Its `operatorDAInput` is a single ABI-encoded state-diff hash. The validator does not compare that
value with the ZKsync OS DA commitment and returns zero-filled compatibility arrays for the legacy
blob-output fields.

Validity proofs still protect the state transition, but users additionally depend on the external DA
system for the data needed to reconstruct state and exercise data-dependent recovery paths. A chain
made permanent-rollup cannot switch to this weaker availability model unless the configured pair is
explicitly approved as a rollup pair, which the standard validium configuration is not.
