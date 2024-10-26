# L2 specifics

#### Deployment

The L2 deployment process is different from Ethereum.

In L1, the deployment always goes through two opcodes `create` and `create2`, each of which provides its address
derivation. The parameter of these opcodes is the so-called "init bytecode" - a bytecode that returns the bytecode to be
deployed. This works well in L1 but is suboptimal for L2.

In the case of L2, there are also two ways to deploy contracts - `create` and `create2`. However, the expected input
parameters for `create` and `create2` are different. It accepts the hash of the bytecode, rather than the full bytecode.
Therefore, users pay less for contract creation and don't need to send the full contract code by the network upon
deploys.

A good question could be, _how does the validator know the preimage of the bytecode hashes to execute the code?_ Here
comes the concept of factory dependencies! Factory dependencies are a list of bytecode hashes whose preimages were shown
on L1 (data is always available). Such bytecode hashes can be deployed, others - no. Note that they can be added to the
system by either L2 transaction or L1 -> L2 communication, where you can specify the full bytecode and the system will
mark it as known and allow you to deploy it.

Besides that, due to the bytecode differences for L1 and L2 contracts, address derivation is different. This applies to
both `create` and `create2` and means that contracts deployed on the L1 cannot have a collision with contracts deployed
on the L2. Please note that EOA address derivation is the same as on Ethereum.

Thus:

- L2 contracts are deployed by bytecode hash, not by full bytecode
- Factory dependencies - list of bytecode hashes that can be deployed on L2
- Address derivation for `create`/`create2` on L1 and L2 is different
