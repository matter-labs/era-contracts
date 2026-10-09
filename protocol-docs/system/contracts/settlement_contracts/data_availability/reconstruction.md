# State reconstruction

State reconstruction from Ethereum data is a property of rollup DA configurations, not of every DA
mode. With the standard ZKsync OS blob validator, the data committed by the ZKsync OS batch output is
published in EIP-4844 blobs whose versioned hashes are checked on L1.

A reconstruction tool must understand the ZKsync OS batch-output and pubdata formats as well as the
configured L1 validator. The contracts in this repository authenticate the DA commitment and its L1
publication evidence; they do not themselves reconstruct the L2 state.

Validium and custom DA configurations may keep the reconstruction data outside Ethereum. In those
modes, reconstruction additionally depends on the availability guarantees of the selected external
system.
