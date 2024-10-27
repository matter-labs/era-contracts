
# Custom DA layers


### Security notes for Gateway-based rollups

An important note is that when reading the state diffs from L1, the observer will read messages that come from the L2DAValidator. To be more precise, the contract used is `RelayedSLDAValidator` which reads the data and publishes it to L1 by calling the L1Messenger contract.

If anyone could call this contract, the observer from L1 could get wrong data for pubdata for this particular batch. To prevent this, it ensures that only the chain can call it.