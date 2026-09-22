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
    // cut's init is `upgradeFromTransition(transition)`; the FINAL transaction it commits on a
    // chain is served by `l2UpgradeTx(transition, bridgehub, chainId)` on the engine itself.
    #[sol(rpc)]
    interface IDefaultUpgrade {
        function upgradeFromTransition(address _transition) external returns (bytes32);
        function l2UpgradeTx(address _transition, address _bridgehub, uint256 _chainId) external view returns (L2CanonicalTransaction memory);
    }

    // `IBootstrapUpgrade.sol` — the engine of the v34 bootstrap edge. The committed cut's init is
    // `upgradeFromBootstrap(migration)`; the migration object serves the per-chain transaction.
    #[sol(rpc)]
    interface IBootstrapUpgrade {
        function upgradeFromBootstrap(address _migration) external returns (bytes32);
    }

    // `IRegistryBootstrapMigration.sol` — the read surface of the bootstrap object.
    #[sol(rpc)]
    interface IRegistryBootstrapMigration {
        function l2UpgradeTx(uint256 _chainId) external view returns (L2CanonicalTransaction memory);
    }

    // The current upgrade contract at `DiamondCutData.initAddress`. Current upgrades mutate
    // `l2ProtocolUpgradeTx.data` per-chain inside `upgrade()` before hashing. Replaying this
    // view call produces the same canonical transaction hash as the chain upgrade.
    #[sol(rpc)]
    interface ISettlementLayerUpgrade {
        function getL2UpgradeTxData(
            address bridgehub,
            uint256 chainId,
            bytes memory existingTxData
        ) external view returns (bytes memory);

        function upgradeVerifierOnly(uint256 _newProtocolVersion) external returns (bytes32);
    }

    // Upgrade contracts from v31 through the runtime cut expose the same rewrite with the
    // retired VM discriminator. The readiness checker keeps this binding because it can also
    // be used to monitor those already-published upgrades.
    #[sol(rpc)]
    interface ILegacySettlementLayerUpgrade {
        function getL2UpgradeTxData(
            address bridgehub,
            uint256 chainId,
            bool zksyncOS,
            bytes memory existingTxData
        ) external view returns (bytes memory);
    }
}
