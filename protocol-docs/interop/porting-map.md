# `zksync-era` interop documentation porting map

The first commit of this documentation change ports the `kl/interop-docs` source tree without edits.
This map accounts for every source page in the final, current documentation. A source page may be
superseded rather than retained under its old filename when its architecture no longer exists.

| Ported source                                         | Current home                                                                                                                                             |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `interop/overview.md`                                 | [Interop reading guide](./README.md) and [architecture](./architecture.md#system-map)                                                                    |
| `interop/interop_center/overview.md`                  | [Protocol layers](./architecture.md#protocol-layers), source/destination architecture, and examples                                                      |
| `interop/interop_center/bundles_calls.md`             | {protocol-docs/interop.md#core-data-structures-commonmessagingsol} and [protocol layers](./architecture.md#protocol-layers)                              |
| `interop/interop_center/interop_center.md`            | {protocol-docs/interop.md#send-flow} and [source architecture](./architecture.md#source-architecture)                                                    |
| `interop/interop_center/interop_messages.md`          | [Settlement and proof transport](./architecture.md#settlement-and-proof-transport) and {protocol-docs/message-root.md}                                   |
| `interop/interop_center/interop_trigger.md`           | [Removed trigger model](./architecture.md#protocol-layers), [execution and gas](./architecture.md#execution-and-gas), and [fees](./architecture.md#fees) |
| `interop/interop_messages.md`                         | [Settlement and proof transport](./architecture.md#settlement-and-proof-transport) and [message example](./examples/cross_chain_message.md)              |
| `interop/interop_handler.md`                          | {protocol-docs/interop.md#destination-side-processing-interop-handlers} and [destination architecture](./architecture.md#destination-architecture)       |
| `interop/standard_trigger_account.md`                 | [Sender identity](./architecture.md#sender-identity); the account was removed                                                                            |
| `interop/interop_fees.md`                             | {protocol-docs/interop.md#fee-model} and [fees](./architecture.md#fees)                                                                                  |
| `interop/forms_of_finality.md`                        | [Forms of interop finality](./forms_of_finality.md)                                                                                                      |
| `interop/message_root.md`                             | {protocol-docs/message-root.md} and [proof transport](./architecture.md#settlement-and-proof-transport)                                                  |
| `design/atomicity_using_l1_finality.md`               | {protocol-docs/atomicity/README.md}, especially flow, proofs, recovery, and security                                                                     |
| `design/atomicity_using_da_and_onchain_simulation.md` | [Implemented atomicity differences](./architecture.md#atomicity-and-failure-paths) and {protocol-docs/atomicity/README.md}                               |
| `interop/examples/cross_chain_message.md`             | [Cross-chain message](./examples/cross_chain_message.md)                                                                                                 |
| `interop/examples/cross_chain_swap.md`                | [Atomic multi-leg flow](./examples/cross_chain_swap.md)                                                                                                  |
| `interop/examples/interop_request_two_bridges.md`     | [Cross-chain asset transfer](./examples/asset_transfer.md) and {protocol-docs/bridging.md}                                                               |
| `interop/examples/interop_request_direct.md`          | [Funding and base tokens](./architecture.md#funding-and-base-tokens), {protocol-docs/bridging.md}, and {protocol-docs/chain-lifecycle.md}                |
| `interop/examples/interop_ctm_deployment.md`          | {protocol-docs/chain-lifecycle.md}; CTM deployment is not an `InteropCenter` operation                                                                   |
| `interop/examples/cross_chain_paymaster.md`           | [Execution and gas](./architecture.md#execution-and-gas); trigger/paymaster bundles were removed                                                         |
| `interop/examples/README.md`                          | [Current examples](./examples/README.md)                                                                                                                 |

## Retired diagrams

The port includes 22 raster diagrams. They depict the removed trigger, AliasedAccount,
StandardTriggerAccount, automatic-execution, public message-proof L2 -> L2, and old MessageRoot
layouts, so retaining them in the final tree would make the updated text misleading. The live system
map in [architecture](./architecture.md#system-map) replaces them with a diagram that is reviewable as
text and changes with the contracts.

The first commit remains the archival comparison point for every original image and page. The final
tree intentionally contains no duplicate historical specification that could be mistaken for current
protocol behavior.
