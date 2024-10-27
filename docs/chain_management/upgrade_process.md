# TODO 
# Upgrade process document
[back to readme](../README.md)

## Intro

Upgrading the ecosystem of ZKChains is a complicated process. ZKSync is a complex ecosystem with many chains and contracts and each upgrade is unique, but there are some steps that repeat for most upgrades. These are mostly how we interact with the CTM, the diamond facets, the L1→L2 upgrade, how we update the verification keys.

Where each upgrade consists of two parameters:

- Facet cuts - change of the internal implementation of the diamond proxy
- Diamond Initialization - delegate call to the specified address with specified data

The second parameter is very powerful and flexible enough to move majority of upgrade logic there. However, until this day we had no ready or semi-finished template for the diamond initialization and now we are did the template for the upgrades with the most common and more likely needs.

There are two contracts for this,

1. [BaseZkSyncUpgrade](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/upgrades/BaseZkSyncUpgrade.sol) - Generic template with function that can be useful for upgrades
2. [DefaultUpgrade](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/upgrades/DefaultUpgrade.sol) - Default implementation of the [BaseZkSyncUpgrade](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/upgrades/BaseZkSyncUpgrade.sol), contract that is most often planned to be used as diamond intialization when doing upgrades.

While usually every upgrade is different, a common part can be distinguished, that’s their job.

### Protocol version

For tracking upgrade versions on different networks (private testnet, public testnet, mainnet) we use protocol version, which is basically just a number denoting the deployed version. The protocol version is different from Diamond Cut `proposalId`, since `protocolId` only shows how much upgrade proposal was proposed/executed, but nothing about the content of upgrades, while the protocol version is needed to understand what version is deployed.

In the [BaseZkSyncUpgrade](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/upgrades/BaseZkSyncUpgrade.sol) & [DefaultUpgrade](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/upgrades/DefaultUpgrade.sol) we allow to arbitrarily increase the proposal version while upgrading a system, but only increase it. We are doing that since we can skip some protocol versions if for example found a bug there (but it was deployed on another network already).



#

This upgrade tx:

- force deploys and updates base system contracts
- updates base system contracts, bootloader, default AA

<!-- ## L2 contracts

Besides usual L1 changes as verifier, allowlist, bootloader & default account change, we want to have the ability to execute arbitrary L1 → L2 transactions while doing an upgrade.

We already practiced doing that with different [DiamondUpgradeInit](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/zksync/upgrade-initializers/DiamondUpgradeInit6.sol#L12), which was also used as a diamond initialization. The idea was that operator runs an upgrade and make a delegate call to the [DiamondUpgradeInit](https://github.com/matter-labs/zksync-2-contracts/blob/sb-new-upgrade-system/ethereum/contracts/zksync/upgrade-initializers/DiamondUpgradeInit6.sol#L12), which place pre-set L1 → L2 transaction in the priority queue. Later that transaction could be executed in the same manner as any other L1 → L2 transaction, even though that specific upgrade transaction wasn’t actually requested by authorized user with as other transactions.

Now, we introduce system contracts upgrade transactions. This is a separate transaction type, different from all other transaction types. The transaction with this transaction type can be processed only first in the block (enforced by bootloader) and requested onchain only during the upgrade. On the L1, this transaction is stored not even on the priority queue, but rather in a specific storage slot, separate from all other transactions.

❗Since this transaction should be handled only once we keep track of which block it is executed, considering the possibility that the block can be reverted at any moment (`revertBlocks`), error in this functionality is specifically susceptible to attacks. -->

## STM interactions

- Context: all upgrade txs are sent via the Governance contract via a scheduleTransparent and execute operations. This can call any of our contracts, the Governance is the owner of all of them.
- Previously we called the DiamondProxy directly with the diamond cut. After v0.24.1 we call the STM which records the diamondCut hash in a mapping(protocolVersion ⇒ upgradeCutHash) . After this the chainAdmin can call the Admin facet of their chain with the same diamondCut data, and this executes the diamondCut ( the provided diamondCut is checked against the upgradeCutHash in the STM)

## Contracts involved in the L1→L2 tx:

### L1

- The L1→L2 upgrade tx is set via the DiamondCut via the DefaultUpgrade / BaseZkSyncUpgrade. The server picks the diamondCut up similarly to how it pick up the PQ transaction, and executes it. The upgrade tx is special, it has its own tx type, an L2→L1 system log is sent with the upgrade tx hash, and this L2→L1 log is compared in the Executor facet with the currently recorded upgrade tx hash when the batch is executed. If the hash is incorrect the upgrade fails.

### L2

- ComplexUpgrader.sol
    - This is the general L2 System Contract that can execute any upgrade by delegateCalling an implementation upgrade contract. This implementation can change for each upgrade, it might inherit the ForceDeployUpgrader.sol
- ForceDeployUpgrader.sol
    - Is a standard L2 implementation. It is used to call the ContractDeployer to force deploy contracts. In itself it is not really useful ( as the FORCE_DEPLOYER address can also do this), but if a custom upgrade implementation inherits it then it is useful.
- ContractDeployer.sol
    - The contract that deploys all contracts. It also supports ForceDeployments when called from the ComplexUpgrader or the FORCE_DEPLOYER address ( which is not the address of the ForceDeployUpgrader) .
- GenesisUpgrade (WIP for Gateway). This will be the upgrade used in the genesis upgrade to deploy the Bridgehub. ( we need to use it as the BH has a constructor). We will also use this in the future to deploy the custom base token contract.