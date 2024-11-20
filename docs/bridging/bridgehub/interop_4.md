# InteropExplained - ep 4 - Interop Transactions

# Basics

The InteropTransaction sits at the top of our interop stack, acting as the “delivery” mechanism for Interop Bundles.

Think of it like a car that picks up our "hitchhiker" bundles and carries them to their destination.

![image.png](./img/message_layers_C.png)

**Note:** Interop Transactions aren't the only way to execute a bundle. Once an interop bundle is created on the source chain, users can simply send a regular transaction on the destination chain to execute it.

However, this approach can be inconvenient because it requires users to have funds on the destination chain to cover gas fees and to configure the necessary network settings (like the RPC address).

InteropTransactions simplify this by handling everything from the source chain. You can select which interopBundle to execute, specify gas details (like gas amount and gas price), and decide who will cover the gas costs (for example, by using tokens on the source chain or through a paymaster).

After that, the transaction will be auto-executed - either by the chain operator, or by off-chain tools.

An InteropTransaction contains two pointers to bundles:

- **feesBundle**: Holds interop calls to cover fees
- **bundleHash**: Contains the main execution

![image.png](./img/interop_tx_structure.png)

## Interface

The function here `sendInteropTransaction` has all the options. For simpler use cases, see the helper methods that are defined later in the article.

```solidity
contract InteropCenter {
  /// Creates a transaction that will attempt to execute a given Bundle on the destination chain.
  /// Such transaction can be 'picked up' by the destination chain automatically.
  /// This function covers all the cases - we expect most users to use the helper
  /// functions defined later.
 function sendInteropTransaction(
  destinationChain,
  bundleHash,        // the main bundle that you want to execute on destination chain
  gasLimit,          // gasLimit & price for execution
  gasPrice,
  feesBundleHash,  // this is the bundle that contains the calls to pay for gas
  destinationPaymaster,  // optionally - you can use a paymaster on destination chain
  destinationPaymasterInput); // with specific params


 struct InteropTransaction {
  address sourceChainSender
  uint256 destinationChain
   uint256 gasLimit;
   uint256 gasPrice;
   uint256 value;
   bytes32 bundleHash;
   bytes32 feesBundleHash;
    address destinationPaymaster;
   bytes destinationPaymasterInput;
 }
}
```

After creating the InteropBundle, you can simply call `sendInteropTransaction` to create the full transaction that will go and execute that bundle.

# Retries

If your transaction fails to execute the bundle (e.g., due to a low gas limit) or isn’t even included (e.g., due to too low gasPrice), you can always send another transaction to **attempt to execute the same bundle again**.

Just call `sendInteropTransaction` again, but this time with different gas settings.

### Example of retrying

Here’s a concrete example: Suppose you created a bundle to perform a swap that includes transferring 100 ETH, completing the swap, and transferring some tokens back.

You attempted to send the interop transaction with a low gas limit (e.g., 100). Since you didn’t have any base token on the destination chain, you created a separate bundle to transfer a small fee (e.g., 0.0001) to cover the gas.

You sent your first interop transaction to the destination chain, but it failed due to insufficient gas. Even though the transaction failed, your “fee bundle” was successfully executed, as it covered the gas cost for the failed attempt.

Now, you have two options: either cancel the execution bundle (the one with 100 ETH) or try again.

To retry, you decide to set a higher gas limit (e.g., 10,000) and create another fee transfer (e.g., 0.01) but use **the same execution bundle** as before.

This time, the transaction succeeds—the swap completes on the destination chain, and the resulting tokens are transferred back to the source chain.

![image.png](./img/interop_txs_reexec.png)

# Fees & restrictions

Using an InteropBundle for fee payments provides flexibility, allowing users various options. The idea is to use the InteropBundle to transfer a small amount, just enough to cover the fee, while keeping the main assets within the execution bundle itself.

## Restrictions

This flexibility comes with trade-offs, similar to those in Account Abstraction or ERC4337 validation phases, primarily aimed at preventing DoS attacks.

- Lower gas limits
- Limited access to specific slots

Additionally, when the INTEROP_CENTER constructs an InteropTransaction, it enforces extra restrictions on these **feePaymentBundles**:

- **Restricted executors**: Only your AliasedAccount on the receiving side can execute the feePaymentBundle.

This restriction is mainly for security, preventing others from executing your **fee bundle**, which could cause your transaction to fail and prevent the **execution bundle** from processing.

## Types of fees

### Using destination chain’s base token

The simplest scenario, is when you (as the sender) already have the destination’s chain base token on the source chain.

For example - if you send transaction from ERA (base token - ETH) to Sophon (base token - SOPH) - if you already have SOPH on ERA.

For this, we’ll offer a helper function:

```solidity
 contract InteropCenter {
  // Creates InteropTransaction to the destination chain with payment with base token.
  // Before calling, you have to 'approve' InteropCenter to the ERC20/Bridge that holds the destination chain's base tokens.
  // or if the destination chain's tokens are the same as yours, just attach value to this call.
  function sendInteropTxMinimal(
   destinationChain,
   bundleHash,        // the main bundle that you want to execute on destination chain
   gasLimit,          // gasLimit & price for execution
   gasPrice,
  );
 }
```

### Using paymaster on the destination chain

If you don’t have the base token from the destination chain (SOPH in our example) on your source chain, you’ll have to use some paymaster on destination chain instead.

You will send the token that you have (for example USDC) over to the destination chain (as a part of the feeBundleHash), and then give it to the paymaster on the destination chain to cover your gas fees.

Your interop Transaction would look like this:

![image.png](./img/interop_tx_paymaster.png)

# Automatic execution

One of the main advantages of InteropTransactions is that they execute automatically. As the sender on the source chain, you don’t need to worry about technical details like RPC addresses or obtaining proofs – it’s all managed for you.

After creating an InteropTransaction, it can be relayed to the destination chain by anyone. The transaction already includes a signature (also known as an interop message proof), making it fully self-contained and ready to send without needing extra permissions.

Usually, the destination chain’s operator will handle and include incoming InteropTransactions. However, if they don’t, the Gateway or other participants can step in to prepare and send them.

You can also use the available tools to create the destination transaction and send it yourself. Since the transaction is self-contained, it doesn’t require additional funds or signatures to complete.

![Usually destination chain operator will keep querying gateway to see if there are any messages for their chain.](./img/automatic_exec.png)

Usually destination chain operator will keep querying gateway to see if there are any messages for their chain. The sending chain will also automatically forward the transaction to the destination chain.

Once they see the message, they can ask chain for the proof and also fetch the InteropBundles that this message contains (together with their proofs).

![Operator getting necessary data from Gateway](./img/automatic_exec_2.png)

Operator getting necessary data from Gateway

As the final step, the operator can use the received data to create **regular** transaction - that it can then send to their chain.

![creating the final transaction to send to the destination chain](./img/automatic_exec_3.png)

creating the final transaction to send to the destination chain

The steps above didn’t require any special permissions, and can be executed by anyone.

While Gateway was used above to do things like providing proofs etc - in case Gateway becomes malicious - all this information can be constructed off-chain from the L1-available data.

### How it works under the hood?

We’ll modify the default account - so that it can accept the interop proofs as signatures - nicely fitting into the current ZKSync native AccountAbstraction model.
