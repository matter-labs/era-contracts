# 概述
zkSync Era是一个无需许可的通用ZK rollup，类似于许多L1区块链和侧链，它可以部署和与图灵完备的智能合约进行交互。

- L2智能合约在zkEVM上执行。
- zkEVM字节码与L1 EVM不同。
- 有Solidity和Vyper编译器用于L2智能合约。
- 有一种标准的方法来在L1和L2之间传递消息，这是协议的一部分。
- 目前还没有逃生门机制，但未来会有一个。

所有恢复L2状态所需的所有数据也会被推送到L1链上。有两种方法，一种是在链上发布L2交易的输入，另一种是发布状态转换差异。zkSync采用第二种选项。


请查阅[文档](https://v2-docs.zksync.io/dev/fundamentals/rollups.html)以了解更多信息！

## 词汇表
- **Governor** - 特权地址，用于控制网络的可升级性并设置其他特权地址。
- **Validator/Operator** - 一个特权地址，可以提交/验证/执行L2块。
- **Facet** - 实现合约。这个词来自于[EIP-2535](https://eips.ethereum.org/EIPS/eip-2535)。
- **Security council** - 一组受信任的地址，可以减少升级锁定时间。
- **Gas** - 是一种计量单位，用于衡量在zkSync v2网络上执行特定操作所需的计算工作量。


### L1智能合约

#### Diamond

从技术上讲，这个 L1 智能合约作为以太坊（L1）和 zkSync（L2）之间的连接器。该合约用来检查有效性证明和数据可用性，处理 L2 <-> L1 通信，完成 L2 状态转换等。

还有在 L2 上部署的重要合约，可以执行逻辑称为 __系统合约__。通过 L2 <-> L1 通信，它们可以同时影响 L1 和 L2。

#### DiamondProxy

主合约使用[EIP-2535](https://eips.ethereum.org/EIPS/eip-2535)钻石代理模式。这是一种内部实现，灵感来自于[mudgen参考实现](https://github.com/mudgen/Diamond)。它没有外部函数，只有fallback函数，将调用委托给其中一个facets（目标/实现合约）。因此，即使升级系统也是可以替换的独立facets。

与参考实现的其中一个区别是访问冻结性。每个facets都有一个相关参数，指示是否可能冻结对该facets的访问。特权操作员可以冻结**钻石**（而不是特定的facets！），并且所有带有标记`isFreezable`的facets应该是不可访问的，直到管理员解冻钻石。请注意，这是非常危险的事情，因为钻石代理可以冻结升级系统，然后钻石将永久冻结。


#### DiamondInit

这是一个单函数合约，用于实现初始化钻石代理的逻辑。它仅在钻石构造函数中调用一次，不会作为facet保存在钻石中。

实现细节 - 函数返回一个类似于[EIP-1271](https://eips.ethereum.org/EIPS/eip-1271)中设计的神奇值，但神奇值的大小为32个字节。



#### DiamondCutFacet

这些智能合约管理钻石代理的冻结/解冻和升级。也就是说，合约绝不能被冻结。

目前，冻结和解冻是作为访问控制函数实现的。它完全由治理者控制，但后续可以进行更改。治理者可以调用 `freezeDiamond` 冻结钻石，以及 `unfreezeDiamond` 恢复它。

`DiamondCutFacet` 的另一个目的是升级facets。升级分为2-3个阶段：

- `proposeTransparentUpgrade` / `proposeShadowUpgrade` - 提出具有可见/隐藏参数的升级提案。
- `cancelUpgradeProposal` - 取消升级提案。
- `securityCouncilUpgradeApprove` - 安全委员会批准升级。
- `executeUpgrade` - 完成升级。

升级本身由三个变量特征化：

- `facetCuts` - 一组对facets的更改（添加新facets，删除facets和替换facets）。
- 对 `(address _initAddress，bytes _calldata)` 的配对，通过对 `_initAddress` 进行委托调用并使用 `_calldata` 输入进行初始化升级。


#### GettersFacet

独立的 facet，其唯一的功能是提供 `view` 和 `pure` 方法。它还实现了[diamond loupe](https://eips.ethereum.org/EIPS/eip-2535#diamond-loupe)，使管理 facet 更加容易。

#### GovernanceFacet

控制更改特权地址，例如治理者和验证者或其中一个系统参数（L2 bootloader bytecode hash、verifier address、verifier parameters 等）。

在当前阶段，治理者有权限使用 `GovernanceFacet` 立即更改关键系统参数。后续将删除此类功能，系统参数的更改将仅能通过钻石升级进行（请参见_DiamondCutFacet_）。


#### MailboxFacet

这个 facet 处理 L2 <-> L1 通信，可以在[文档](https://v2-docs.zksync.io/dev/developer-guides/bridging/l1-l2-interop.html)中找到概述。

Mailbox 执行三个功能：

- L1 <-> L2 通信。
- 将 Ether 桥接到 L2。
- 抗审查机制（尚未实现）。

L1 -> L2 通信是通过在 L1 上请求 L2 交易并在 L2 上执行来实现的。这意味着用户可以在 L1 合约上调用函数，将有关交易的数据保存在某些队列中。稍后，验证者可以在 L2 上处理它们并在 L1 优先级队列上将其标记为已处理。目前，它用于从 L1 发送信息到 L2 或实现多层协议。

_注_：虽然用户从 L1 请求交易，但在 L2 上发起的交易将具有这样的 `msg.sender`：


```solidity
  address sender = msg.sender;
  if (sender != tx.origin) {
      sender = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
  }
```

其中

```solidity
uint160 constant offset = uint160(0x1111000000000000000000000000000000001111);

function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
  unchecked {
    l2Address = address(uint160(l1Address) + offset);
  }
}

```

L1 -> L2通信也可用于桥接以太币。用户在L1合约上发起交易请求时，应包含 `msg.value`。在L2上执行交易之前，指定的地址将获得资金。用户应调用 `L2EtherToken` 系统合约上的 `withdraw` 函数来提取资金。这将在L2上销毁资金，允许用户通过 `MailboxFacet` 上的 `finalizeEthWithdrawal` 函数来取回它们。


与L1 -> L2通信相比，L2 -> L1通信仅基于信息传递，而不是在L1上执行交易。

从L2方面来看，有一个特殊的zkEVM操作码，可以将 `l2ToL1Log` 保存在L2块中。当验证者向L1发送L2块时（请参见 `ExecutorFacet`），将发送所有 `l2ToL1Logs`。稍后，用户将能够在L1上读取他们的 `l2ToL1Logs` 并 _证明_ 他们发送了它。

从L1方面来看，对于每个L2块，都会计算带有这些日志的Merkle根。因此，用户可以为每个 `l2ToL1Logs` 提供Merkle证明。

_注_：对于每个执行的L1 -> L2交易，系统程序必须发送一个L2 -> L1日志。为了验证执行状态，用户可以使用 `proveL1ToL2TransactionStatus`。

_注_： `l2ToL1Log` 结构由固定大小的字段组成！因此，从L2发送大量数据并仅使用 `l2ToL1log` 证明它们已发送到L1是不方便的。为了发送可变长度的消息，我们使用以下技巧：

- 系统合约之一接受任意长度的消息，并使用参数 `senderAddress == this`、`marker == true`、`key == msg.sender`、`value == keccak256(message)` 发送固定长度的消息。
- L1上的合约接受所有发送的消息，如果消息来自此系统合约，则要求提供 `value` 的原像。

#### ExecutorFacet

一个接受L2区块、强制数据可用性并检查zk证明有效性的合约。

状态转换分为三个阶段：

- `commitBlocks` - 检查L2区块时间戳，处理L2日志，保存块数据并为zk证明准备数据。
- `proveBlocks` - 验证zk证明。
- `executeBlocks` - 完成状态转换，标记L1 -> L2通信处理，并保存带有L2日志的Merkle树。

当提交块时，我们会处理 L2 -> L1 日志。以下是预期存在的不变量：

- 来自 `L2_SYSTEM_CONTEXT_ADDRESS` 的唯一 L2 -> L1 日志，其 `key == l2BlockTimestamp` 和 `value == l2BlockHash`。
- 来自 `L2_KNOWN_CODE_STORAGE_ADDRESS` 的几个（或零个）日志，其中 `key == bytecodeHash`，字节码被标记为已知的工厂依赖项。
- 来自 `L2_BOOTLOADER_ADDRESS` 的几个（或零个）日志，其中 `key == canonicalTxHash`，`canonicalTxHash` 是处理的L1 -> L2交易的哈希。
- 来自 `L2_TO_L1_MESSENGER` 的几个（或零个）日志，其中 `value == hashedMessage`，`hashedMessage` 是从L2发送的任意长度消息的哈希。
- 没有来自其他地址的日志（可能会在将来更改）。


#### Bridges

Bridges是完全独立于Diamond的合约。它们是用于在L1和L2上通信的合约的包装器。
在一个层上锁定资产后，会发送请求在另一个层上铸造这些桥接资产。在一个层上燃烧资产后，会发送请求在另一个层上解锁它们。

与Ether桥接不同，所有其他资产都可以通过依赖于无信任L1 <-> L2通信的自定义实现进行桥接。


##### L1ERC20Bridge

- `deposit` - 将资金锁定在合约内，并发送请求在L2上铸造桥接资产。
- `claimFailedDeposit` - 如果存款已启动但在L2上失败，则解锁资金。
- `finalizeWithdrawal` - 为来自L2的有效提款请求解锁资金。

##### L2ERC20Bridge

- `withdraw` - 通过在合约上燃烧资金并向L1发送相应的消息来发起提款。
- `finalizeDeposit` - 完成存款并在L2上铸造资金。


#### Allowlist

这是辅助合约用来控制许可访问列表。它在桥接和Diamond代理中用于控制在Alpha版本哪些地址可以与它们交互。

### L2的具体信息

#### 部署

L2的部署过程与以太坊不同。

在L1中，部署始终通过两个操作码 `create` 和 `create2` 进行，每个操作码都提供其地址派生。这些操作码的参数是所谓的“init bytecode” - 返回要部署的字节码的字节码。这在L1中很有效，但对于L2来说不是最优的。


在L2中，也有两种部署合约的方式 - `create` 和 `create2`。但是，`create` 和 `create2` 的期望输入参数是不同的。它接受字节码的哈希，而不是完整的字节码。因此，用户在部署合约时不需要发送完整的合约代码到网络上，这样可以减少合约
创建的成本。

一个好的问题可能是，“验证人如何知道字节码哈希的原像以执行代码？” 这里就出现了工厂依赖的概念！ 工厂依赖是一组字节码哈希列表，其中哈希原像在L1上已经显示过（数据始终可用）。 这样的字节码哈希可以部署，其他的则不行。 请注意，它们可以通过L2事务或L1 -> L2通信添加到系统中，在其中可以指定完整的字节码，系统将标记它为已知并允许您部署它。 

除此之外，由于L1和L2合约的字节码不同，地址派生也不同。这适用于`create`和`create2`，意味着在L1上部署的合约与在L2上部署的合约不能冲突。请注意，EOA地址派生与以太坊相同。

因此：

- L2合约是由字节码哈希部署的，而不是完整字节码
- 工厂依赖项 - 可在L2上部署的字节码哈希列表
- 在L1和L2上，`create`/`create2`的地址派生不同

### 提现/存款限制


决定对从协议中提取和存入的资金数量进行限制。

#### 提现限制

如果恶意用户在 L2 上非法铸造了一些代币，则应该有限制，不允许恶意用户在 L1 上提取所有资金。目前的计划是在协议层面上设置提现限制。换句话说，不允许每天提取数额超过协议余额的一定百分比。通过治理交易，可以将代币添加到提现限制列表中，并定义每天允许提取的百分比。

```solidity
struct Withdrawal {
  bool withdrawalLimitation;
  uint256 withdrawalFactor;
}

```

#### 存款限制

为了保险起见，存款金额也将受到限制。这个限制是应用在账户级别的，不是基于时间的。换句话说，每个账户无法存款超过定义的上限。代币和上限可以通过治理交易来设置。此外，还有一个白名单机制（只有某些列入白名单的账户才能调用某些特定的函数）。因此，存款限制和白名单的结合将导致白名单账户的存款量低于定义的上限。

```solidity
struct Deposit {
  bool depositLimitation;
  uint256 depositCap;
}

```

请查阅[文档](https://v2-docs.zksync.io/dev/developer-guides/contracts/contracts.html#solidity-vyper-support)以了解更多信息！
