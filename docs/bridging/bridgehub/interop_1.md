# InteropExplained - ep 1 - Intro

# Basics

## What is interop?

Interop is a way to communicate: observe messages, send assets, execute calls,  bundle of calls and transactions between two ZKStack chains.

**Observe messages**
Allows you to see that some interop message (think about it as special Event) was created on the source chain.

**Send assets**
Allows you to send different assets (ERC20) between chains.

**Execute calls**
Allows you to call a contract on a remote chain, with given calldata and value. With interop, you automatically get an account (a.k.a aliasedAccount) on each chain, that you can control from the source chain.

**Execute bundle of calls**
Allows you to have multiple remote calls **tied together** in a bundle - making sure that all of them execute at once.

**Execute transactions**
You are able to create a transaction on the source chain, that will be automatically executed on the destination chain - while selecting from different cross-chain Paymaster solutions to cover the gas fees.

## How do I use it?

For the simplest scenario - of executing a contract on a destination chain:

```solidity
cast send source-chain-rpc.com INTEROP_CENTER_ADDRESS sendInteropWithSingleCall(
	0x1fa72e78 // destination_chain_id,
	0xb4AB2FF34fa... // destination_contract,
	0x29723511000000... // destination_calldata,
	0, // value
	100_000, // gasLimit
	250_000_000, // gasPrice
    ..
	)
```

While this looks very similar to ‘regular’ call, there are some caveats, especially around failures and error handling. Please read the FAQ below.

### Simple scenario FAQ

- Who pays for gas?
    - when you use this method, your account must have `gasLimit * gasPrice`  worth of destination chain tokens available on the source chain. (so if you send this request from Era and destination chain is Sophon with SOPH, you must have SOPH tokens on Era)
    - There are of course far more payment options (but that’s in later sections).
- How does the destination contract know it is from me?
    - destination contract will be called with `msg.sender` equal to `keccak(source_account, source_chain)[:20]`  (in the perfect world, we would have used `source_account@source_chain` - similar to how email works - but as we have to fit into 20 bytes ethereum address, we do a keccak).
- Who executes it on the destination chain?
    - This call will be ‘auto executed’ on the destination chain. You as a user don’t have to do anything.
- What if it fails out of gas? Or what if I set too low gasPrice?
    - In either of these scenarios, you can ‘retry’ it, by using `retryInteropTransaction` (not implemented yet).
        
        ```solidity
        cast send source-chain.com INTEROP_CENTER_ADDRESS retryInteropTransaction(
          0x2654.. // previous interop transaction hash from above
          200_000, // new gasLimit
          300_000_000 // new gasPrice
         )
        ```
        
    - IMPORTANT: depending on your use case, it might be very important to retry rather than to create a new `sendInteropWithSingleCall` - for example if your call includes some larger asset transfer, creating the new `sendInteropWithSingleCall` would attempt to freeze/burn these assets again.
- If some of my assets were burned when I did the transaction, but it failed on destination chain, how do I get them back?
    - If your transaction failed on destination chain, you can either try to retry it with more gas, higher gas limits (see above) or cancel it (not implemented yet):
        
        ```solidity
        cast send source-chain INTEROP_CENTER_ADDRESS cancelInteropTransaction(
        	0x2654.. // previous interop transaction
        	100_000 // gasLimit (yes, cancellation needs gas too - but just to mark as cancelled)
        	300_000_000 // gasPrice
        )
        ```
        
    - after that, you’ll need to call the `claimFailedDeposit` methods on your source chain contracts to get the assets that were burned when you did the transaction back - details of those are contract specific.

### Complex scenario

What if I want to transfer some USDC to Sophon chain, then swap to PEPE coin, and then transfer the results back?

You’ll have to create a bunch of **InteropCalls** (transfer USDC, do a swap etc), then put them into a common **InteropBundle,** and then create the InteropTransaction to execute them on the destination chain.

The exact details will be in the next article.

# Technical details

### How does native bridging differ from a third party bridging?

There are roughly 2 types of bridges: Native and third party.

Normal native bridging allows you to bridge assets ‘up and down’ (so from L2 to L1 and from L1 to L2), interop (which is also a form of native bridging) allows you to move them between different L2s. So instead of doing the ‘round trip’ (from source L2 to L1, and then from L1 to destination L2), you can go between 2 L2s directly, saving you both the latency and cost.

Third party bridging can work between 2 different L2s, but it depends on its own liquidity. So while you as a user, get your assets on destination chain ‘immediately’, they are actually coming from the bridge’s own tokens, and liquidity providers have to rebalance them using native L1<>L2 bridges (which means that they need to have a reserve of tokens on both sides, which cost them money, which usually results in higher fees).

The good news, is that third party bridges can use interop to improve the transfers of their tokens too - by using the InteropMessage layer - more details below.

### How fast is it?

Interop speed depends on its lowest level - InteropMessage propagation speed - which boils down to the question, at which moment are you (as destination chain) sure that the message created by source chain is valid.

As security is our top priority, the default Interop will wait for the ZK proof - which might take around 10 minutes. 

At the same time, we plan to release another INTEROP_CENTER contract (under a different address, but with same interface) - that would work within 1 second, but with additional risks (similar to optimistic chains).

### 4 Levels of interop

When analysing interop, you can break it into 4 levels - which allows you to choose the level to integrate on:

- InteropMessages - lowest level - directly used by 3rd party bridges and other protocols.
- Interop Call - medium level - used by ‘library’ contracts.
- InteropCallBundle - high level - used by ‘user-visible’ contracts.
- InteropTransaction - highest level - used by UX & frontends.

![image.png](./img/message_layers.png)

We will be covering the details of each layer in the next articles.