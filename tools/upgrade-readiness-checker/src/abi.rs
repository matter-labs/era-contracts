//! Contract ABIs needed to locate the pending upgrade transaction and resolve the
//! chain's ChainTypeManager.

alloy::sol! {
    // Matches `Messaging.sol::L2CanonicalTransaction`. Hashing this struct (ABI-encoded)
    // yields the canonical priority-op tx hash that the L2 server produces a receipt for.
    struct L2CanonicalTransaction {
        uint256 txType;
        uint256 from;
        uint256 to;
        uint256 gasLimit;
        uint256 gasPerPubdataByteLimit;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 paymaster;
        uint256 nonce;
        uint256 value;
        uint256[4] reserved;
        bytes data;
        bytes signature;
        uint256[] factoryDeps;
        bytes paymasterInput;
        bytes reservedDynamic;
    }

    // `IChainTypeManager.sol`
    #[sol(rpc)]
    interface IChainTypeManager {
        enum Action {
            Add,
            Replace,
            Remove
        }

        struct FacetCut {
            address facet;
            Action action;
            bool isFreezable;
            bytes4[] selectors;
        }

        struct DiamondCutData {
            FacetCut[] facetCuts;
            address initAddress;
            bytes initCalldata;
        }

        struct VerifierParams {
            bytes32 recursionNodeLevelVkHash;
            bytes32 recursionLeafLevelVkHash;
            bytes32 recursionCircuitsSetVksHash;
        }

        // The LEGACY cut-taking shape (pre-v34 commits): `DefaultUpgrade.upgrade(ProposedUpgrade)`.
        // Registry-driven cuts (v34+) carry an object address instead — see the interfaces below.
        struct ProposedUpgrade {
            L2CanonicalTransaction l2ProtocolUpgradeTx;
            bytes32 bootloaderHash;
            bytes32 defaultAccountHash;
            bytes32 evmEmulatorHash;
            address verifier;
            VerifierParams verifierParams;
            bytes l1ContractsUpgradeCalldata;
            bytes postUpgradeCalldata;
            uint256 upgradeTimestamp;
            uint256 newProtocolVersion;
        }

        /// Emitted when governance publishes the data for a new upgrade cut.
        event NewUpgradeCutData(uint256 indexed protocolVersion, DiamondCutData diamondCutData);
    }

    // `IBridgehub.sol` — just what we need to resolve the CTM for a given chain.
    #[sol(rpc)]
    interface IBridgehub {
        function chainTypeManager(uint256 _chainId) external view returns (address);
    }

    // `IDefaultUpgrade.sol` — the engine of a registry-driven transition (v34+). The committed
    // cut's init is `upgradeFromTransition(transition)`; the transaction it commits, before the
    // per-chain rewrite, is served by `l2UpgradeTx(transition, bridgehub)` on the engine itself.
    #[sol(rpc)]
    interface IDefaultUpgrade {
        function upgradeFromTransition(address _transition) external returns (bytes32);
        function l2UpgradeTx(address _transition, address _bridgehub) external view returns (L2CanonicalTransaction memory);
    }

    // `IBootstrapUpgrade.sol` — the engine of the v34 bootstrap edge. The committed cut's init is
    // `upgradeFromBootstrap(migration)`; the migration object serves the transaction.
    #[sol(rpc)]
    interface IBootstrapUpgrade {
        function upgradeFromBootstrap(address _migration) external returns (bytes32);
    }

    // `IRegistryBootstrapMigration.sol` — the read surface of the bootstrap object.
    #[sol(rpc)]
    interface IRegistryBootstrapMigration {
        function l2UpgradeTx() external view returns (L2CanonicalTransaction memory);
    }

    // `SettlementLayerV31UpgradeBase.sol` — the upgrade contract at `DiamondCutData.initAddress`.
    // v31+ chains mutate `l2ProtocolUpgradeTx.data` per-chain inside `upgrade()` before
    // hashing, by calling `getL2UpgradeTxData(bridgehub, chainId, zksyncOS, existingData)`.
    // To get the same canonical tx hash the sequencer will produce, we need to replay that
    // mutation — easiest via an eth_call to the upgrade contract itself. For pre-v31 upgrade
    // contracts this selector does not exist, so the call reverts and we fall back to the
    // unmutated data.
    #[sol(rpc)]
    interface ISettlementLayerUpgrade {
        function getL2UpgradeTxData(
            address bridgehub,
            uint256 chainId,
            bool zksyncOS,
            bytes memory existingTxData
        ) external view returns (bytes memory);
    }
}
