// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";
import {Merkle} from "murky/Merkle.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {
    ETH_TOKEN_ADDRESS,
    MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
} from "contracts/common/Config.sol";
import {
    IBridgehubBase,
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {DenyAllTransactionFilterer} from "contracts/transactionFilterer/DenyAllTransactionFilterer.sol";
import {ShutdownDistributorInstaller} from "contracts/bridge/shutdown/ShutdownDistributorInstaller.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainShutdownUpgrade} from "deploy-scripts/upgrade/ChainShutdownUpgrade.s.sol";
import {IZkSyncLiteSunsetClaimDistributorL1} from "./utils/IZkSyncLiteSunsetClaimDistributorL1.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IMessageRootBase, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TransactionNotAllowed, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {IERC1967} from "@openzeppelin/contracts-v4/interfaces/IERC1967.sol";
import {
    ChainAdminNotOwner,
    ChainIsShutdown,
    ChainNotShutdown,
    ChainValidatorNotRemoved,
    InvalidChainMigrationNumber,
    InvalidSettlementLayer,
    InvalidShutdownDistributor,
    NoChainBalanceToSend,
    NotShutdownChainNativeAsset,
    SettlementLayerCannotBeShutdown,
    ShutdownChainNativeAsset,
    ShutdownChainNativeAssetAlreadyMinted,
    ShutdownDistributorNotInitialized,
    TransactionFiltererNotSet,
    ZKsyncOSChainCannotBeShutdown
} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";

/// @dev This test's ecosystem deployment already deployed implementations of the same code with the default salt, so the
/// upgrade script gets its own salt to deploy new ones and actually move the proxies.
contract ChainShutdownUpgradeForTests is ChainShutdownUpgrade {
    constructor() {
        setCreate2Salt(keccak256("ChainShutdownUpgradeForTests"));
    }
}

/// @notice End-to-end tests of the chain shutdown flow on L1, which needs no changes to the chain's facets:
/// 1. the governance votes for the shutdown; the proposal names a distributor proxy whose admin is the governance and
///    whose implementation lets only the chain admin install the real distributor, once;
/// 2. when ready, the chain admin nominates the governance as the next admin;
/// 3. the governance multicall accepts the admin role, removes the ValidatorTimelock, installs the deny-all filterer
///    and shuts the chain down in the asset tracker, which also sets the distributor and records the chain admin
///    named by the installer;
/// 4. the chain admin installs the real distributor with the snapshot root through the proxy, and mints to it
///    the tokens native to the chain that its users still held on it;
/// 5. anyone sends the chain's L1 funds to the distributor and users claim.
/// @dev Uses the full L1 ecosystem deployment and real deposits through the Bridgehub, no storage overrides.
contract ChainShutdownTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdToml for string;

    uint256 constant GAS_PRICE = 10_000_000;
    uint256 constant L2_GAS_LIMIT = 1_000_000;
    uint256 constant TOKEN_DEPOSIT = 5 ether;

    uint256 chainId;
    address chain;
    address chainAdmin;
    address ctmOwner;
    IL1AssetTracker assetTracker;
    /// @dev The governance: owner of the asset tracker and, after the shutdown multicall, the chain admin.
    address governance;
    address validatorTimelock;
    /// @dev Deployed before the governance proposal, since the proposal's calldata names them.
    address denyAllFilterer;
    address distributorProxy;
    /// @dev The audited distributor implementation that the installer is pinned to.
    address distributorImplementation;
    /// @dev The owner of the distributor (can pause it).
    address distributorOwner = makeAddr("distributorOwner");

    TestnetERC20Token token;
    bytes32 ethAssetId;
    bytes32 tokenAssetId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 ethDeposited;
    /// @dev The L1 -> L2 transaction hash of the last ERC20 deposit, to claim it as a failed deposit.
    bytes32 lastTokenDepositTxHash;

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);
        chainId = zkChainIds[1];
        chain = getZKChainAddress(chainId);
        _addL2ChainContract(chainId, makeAddr("l2Contract"));

        chainAdmin = IZKChain(chain).getAdmin();
        ctmOwner = Ownable2StepUpgradeable(address(addresses.chainTypeManager)).owner();

        assetTracker = IL1AssetTracker(address(addresses.l1NativeTokenVault.l1AssetTracker()));
        address pendingOwner = Ownable2StepUpgradeable(address(assetTracker)).pendingOwner();
        if (pendingOwner != address(0)) {
            vm.prank(pendingOwner);
            Ownable2StepUpgradeable(address(assetTracker)).acceptOwnership();
        }
        governance = Ownable2StepUpgradeable(address(assetTracker)).owner();
        validatorTimelock = addresses.chainTypeManager.validatorTimelockPostV29();
        denyAllFilterer = address(new DenyAllTransactionFilterer());
        distributorImplementation = deployCode(DISTRIBUTOR_ARTIFACT);
        distributorProxy = address(
            new TransparentUpgradeableProxy(
                address(new ShutdownDistributorInstaller(assetTracker, chainId, chainAdmin, distributorImplementation)),
                governance,
                ""
            )
        );

        token = TestnetERC20Token(tokens[0]);
        ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        // Real deposits that give the chain some L1 balance of ETH (base token) and of an ERC20.
        ethDeposited += _depositEth(alice);
        ethDeposited += _depositToken(bob, TOKEN_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                            Helpers
    //////////////////////////////////////////////////////////////*/

    function _baseCost() internal view returns (uint256) {
        return IZKChain(chain).l2TransactionBaseCost(GAS_PRICE, L2_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
    }

    function _depositEth(address _user) internal returns (uint256 mintValue) {
        vm.txGasPrice(GAS_PRICE);
        mintValue = _baseCost() + 1 ether;
        vm.deal(_user, mintValue);
        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect({
            _chainId: chainId,
            _mintValue: mintValue,
            _l2Value: 1 ether,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: ""
        });
        vm.prank(_user);
        addresses.bridgehub.requestL2TransactionDirect{value: mintValue}(request);
    }

    function _depositToken(address _user, uint256 _amount) internal returns (uint256 mintValue) {
        vm.txGasPrice(GAS_PRICE);
        mintValue = _baseCost();
        vm.deal(_user, mintValue);
        token.mint(_user, _amount);
        vm.prank(_user);
        token.approve(address(addresses.l1NativeTokenVault), _amount);

        L2TransactionRequestTwoBridgesOuter memory request = _createL2TransactionRequestTwoBridges({
            _chainId: chainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.sharedBridge),
            _l2Value: 0,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: abi.encode(address(token), _amount, _user)
        });
        vm.prank(_user);
        lastTokenDepositTxHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(request);
    }

    /// @dev Mocks the Merkle proofs of L2 -> L1 messages and of L1 -> L2 transaction statuses: the tests using it are
    /// isolated from the message-root proof verification, everything after it (L1Nullifier, AssetRouter, NTV, asset
    /// tracker) runs for real. The chain settles directly on L1, so the proofs have no settlement-layer part
    /// (`settlementLayerChainId == 0`).
    function _mockMessageRootProofs() internal {
        address messageRoot = address(addresses.bridgehub.messageRoot());
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL1ToL2TransactionStatusShared.selector),
            abi.encode(true)
        );
        ProofData memory proofData;
        vm.mockCall(messageRoot, abi.encodeWithSelector(IMessageRootBase.getProofData.selector), abi.encode(proofData));
    }

    /// @dev Finalizes on L1 a withdrawal sent by the L2 asset router, with the proofs mocked by `_mockMessageRootProofs`.
    function _finalizeWithdrawal(uint256 _l2MessageIndex, bytes32 _assetId, bytes memory _transferData) internal {
        addresses.l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: chainId,
                l2BatchNumber: 0,
                l2MessageIndex: _l2MessageIndex,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: 0,
                message: abi.encodePacked(AssetRouterBase.finalizeDeposit.selector, chainId, _assetId, _transferData),
                merkleProof: new bytes32[](0)
            })
        );
    }

    /// @dev Claims bob's ERC20 deposit as failed, with the proofs mocked by `_mockMessageRootProofs`.
    function _claimFailedTokenDeposit(bytes32 _l2TxHash, uint256 _amount) internal {
        addresses.l1Nullifier.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: bob,
            _l1Token: address(token),
            _amount: _amount,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: new bytes32[](0)
        });
    }

    /// @dev What the chain admin does once it is ready for the shutdown: nominates the governance as the next admin.
    function _handOverAdminToGovernance() internal {
        vm.prank(chainAdmin);
        IZKChain(chain).setPendingAdmin(governance);
    }

    /// @dev The governance proposal, executed as one atomic multicall in production. In this test deployment the
    /// ChainTypeManager may be owned by a different address than the asset tracker, so each call is made by the owner
    /// of its target.
    function _governanceShutdownMulticall() internal {
        vm.prank(governance);
        IZKChain(chain).acceptAdmin();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);
        vm.startPrank(governance);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);
        assetTracker.shutdownChain(chainId, distributorProxy);
        vm.stopPrank();
    }

    function _shutdown() internal {
        _handOverAdminToGovernance();
        _governanceShutdownMulticall();
    }

    function _leaf(uint256 _index, address _claimant, address _token, uint256 _amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_index, _claimant, _token, _amount));
    }

    /// @dev The distributor is the unchanged, audited ZKsync Lite sunset distributor. It is built with the upstream
    /// compiler settings in `vendor/zksync-lite-sunset`, so it is deployed from that artifact.
    string constant DISTRIBUTOR_ARTIFACT =
        "vendor/zksync-lite-sunset/out/ZkSyncLiteSunsetClaimDistributorL1.sol/ZkSyncLiteSunsetClaimDistributorL1.json";

    /// @dev The chain admin upgrades the distributor proxy to the audited distributor and initializes it atomically,
    /// through the one-time `install` of the installer implementation.
    function _installDistributor(
        bytes32 _root,
        uint256 _windowStart
    ) internal returns (IZkSyncLiteSunsetClaimDistributorL1) {
        vm.prank(chainAdmin);
        ShutdownDistributorInstaller(distributorProxy).install(_root, _windowStart, distributorOwner);
        return IZkSyncLiteSunsetClaimDistributorL1(distributorProxy);
    }

    /// @dev A standalone, initialized distributor, to test the distributor itself.
    function _deployDistributor(
        bytes32 _root,
        uint256 _windowStart
    ) internal returns (IZkSyncLiteSunsetClaimDistributorL1) {
        address impl = deployCode(DISTRIBUTOR_ARTIFACT);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            impl,
            makeAddr("distributorProxyAdmin"),
            abi.encodeCall(IZkSyncLiteSunsetClaimDistributorL1.initialize, (_root, _windowStart, distributorOwner))
        );
        return IZkSyncLiteSunsetClaimDistributorL1(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            Shutdown
    //////////////////////////////////////////////////////////////*/

    function test_depositsAreTrackedForTheChain() public view {
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, ethAssetId), ethDeposited);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), TOKEN_DEPOSIT);
    }

    function test_shutdownChain() public {
        assertTrue(IZKChain(chain).isValidator(validatorTimelock));
        _handOverAdminToGovernance();

        uint256 lastExecuted = IZKChain(chain).getTotalBatchesExecuted();
        vm.prank(governance);
        IZKChain(chain).acceptAdmin();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);
        vm.startPrank(governance);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);

        vm.expectEmit(true, false, false, true, address(assetTracker));
        emit IL1AssetTracker.ChainShutdown(chainId, lastExecuted, chainAdmin);
        vm.expectEmit(true, true, false, false, address(assetTracker));
        emit IL1AssetTracker.ShutdownDistributorSet(chainId, distributorProxy);
        assetTracker.shutdownChain(chainId, distributorProxy);
        vm.stopPrank();

        assertTrue(assetTracker.isChainShutdown(chainId));
        (address recordedChainAdmin, address recordedDistributor) = assetTracker.shutdownChainInfo(chainId);
        assertEq(recordedChainAdmin, chainAdmin);
        assertEq(recordedDistributor, distributorProxy);
        // The governance keeps the chain admin role, for future rescue operations.
        assertEq(IZKChain(chain).getAdmin(), governance);
        assertFalse(IZKChain(chain).isValidator(validatorTimelock));
        assertEq(IZKChain(chain).getTransactionFilterer(), denyAllFilterer);
    }

    /// @dev The proposal can be executed only once the chain admin has nominated the governance:
    /// until then, `acceptAdmin` reverts and with it the whole multicall.
    function test_shutdownMulticall_failsUntilChainAdminHandsOver() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        IZKChain(chain).acceptAdmin();
    }

    function test_shutdownChain_onlyOwner() public {
        _handOverAdminToGovernance();
        vm.prank(governance);
        IZKChain(chain).acceptAdmin();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);
        vm.prank(governance);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);

        // Not even the former chain admin can shut down a chain on its own.
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    function test_shutdownChain_requiresGovernanceAsChainAdmin() public {
        vm.prank(chainAdmin);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);

        // The governance has not accepted the admin role.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainAdminNotOwner.selector, chainId, chainAdmin));
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    function test_shutdownChain_requiresTransactionFilterer() public {
        _handOverAdminToGovernance();
        vm.prank(governance);
        IZKChain(chain).acceptAdmin();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(TransactionFiltererNotSet.selector, chainId));
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    function test_shutdownChain_requiresValidatorTimelockRemoved() public {
        _handOverAdminToGovernance();
        vm.startPrank(governance);
        IZKChain(chain).acceptAdmin();
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);

        vm.expectRevert(abi.encodeWithSelector(ChainValidatorNotRemoved.selector, chainId, validatorTimelock));
        assetTracker.shutdownChain(chainId, distributorProxy);
        vm.stopPrank();
    }

    /// @dev Chains created before v29 may still have the legacy ValidatorTimelock as a validator, which this deployment
    /// doesn't set, so the test sets one up.
    function test_shutdownChain_requiresLegacyValidatorTimelockRemoved() public {
        address legacyValidatorTimelock = makeAddr("legacyValidatorTimelock");
        vm.startPrank(ctmOwner);
        addresses.chainTypeManager.setLegacyValidatorTimelock(legacyValidatorTimelock);
        addresses.chainTypeManager.setValidator(chainId, legacyValidatorTimelock, true);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);
        vm.stopPrank();
        _handOverAdminToGovernance();
        vm.startPrank(governance);
        IZKChain(chain).acceptAdmin();
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);

        vm.expectRevert(abi.encodeWithSelector(ChainValidatorNotRemoved.selector, chainId, legacyValidatorTimelock));
        assetTracker.shutdownChain(chainId, distributorProxy);
        vm.stopPrank();
    }

    /// @dev The chain admin of record is read from the installer behind the distributor proxy, so the proxy must
    /// still have it.
    function test_shutdownChain_requiresInstallerAsDistributor() public {
        vm.prank(governance);
        vm.expectRevert(bytes(""));
        assetTracker.shutdownChain(chainId, address(0));

        // An installed distributor has no `CHAIN_ADMIN()`.
        address installedDistributor = address(_deployDistributor(keccak256("root"), block.timestamp));
        vm.prank(governance);
        vm.expectRevert(bytes(""));
        assetTracker.shutdownChain(chainId, installedDistributor);
    }

    /// @dev The installer must be for this chain and this asset tracker, otherwise the chain admin could never
    /// install the distributor.
    function test_shutdownChain_requiresInstallerForTheChain() public {
        _handOverAdminToGovernance();
        vm.prank(governance);
        IZKChain(chain).acceptAdmin();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validatorTimelock, false);
        vm.prank(governance);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);

        address[2] memory wrongInstallers = [
            address(new ShutdownDistributorInstaller(assetTracker, chainId + 1, chainAdmin, distributorImplementation)),
            address(
                new ShutdownDistributorInstaller(
                    IL1AssetTracker(makeAddr("otherAssetTracker")),
                    chainId,
                    chainAdmin,
                    distributorImplementation
                )
            )
        ];
        for (uint256 i = 0; i < wrongInstallers.length; ++i) {
            address wrongProxy = address(new TransparentUpgradeableProxy(wrongInstallers[i], governance, ""));
            vm.prank(governance);
            vm.expectRevert(abi.encodeWithSelector(InvalidShutdownDistributor.selector, chainId, wrongProxy));
            assetTracker.shutdownChain(chainId, wrongProxy);
        }
    }

    /// @dev The installer rejects a zero chain admin in its constructor, so a distributor reporting one is mocked:
    /// `isChainShutdown` is derived from the recorded chain admin, which must not be zero.
    function test_shutdownChain_zeroChainAdmin() public {
        vm.mockCall(
            distributorProxy,
            abi.encodeCall(ShutdownDistributorInstaller(distributorProxy).CHAIN_ADMIN, ()),
            abi.encode(address(0))
        );
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    function test_shutdownChain_settlementLayerCannotBeShutdown() public {
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.setSettlementLayerStatus(chainId, true);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SettlementLayerCannotBeShutdown.selector, chainId));
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    /// @dev This test is isolated from Gateway, which this deployment doesn't have: the bridgehub is mocked to report
    /// that the chain settles on a Gateway.
    function test_shutdownChain_requiresSettlementOnL1() public {
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeCall(IBridgehubBase.settlementLayer, (chainId)),
            abi.encode(block.chainid + 1)
        );
        vm.prank(governance);
        vm.expectRevert(InvalidSettlementLayer.selector);
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    /// @dev This test is isolated from Gateway, which this deployment doesn't have: the chain asset handler is mocked to
    /// report the migration number of a chain that migrated to Gateway and back to L1.
    function test_shutdownChain_requiresNeverMigratedToGateway() public {
        vm.mockCall(
            address(L1AssetTracker(address(assetTracker)).chainAssetHandler()),
            abi.encodeCall(IChainAssetHandlerBase.migrationNumber, (chainId)),
            abi.encode(MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1)
        );
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidChainMigrationNumber.selector, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1, 0)
        );
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    /// @dev This deployment only has Era chains: the chain is mocked to report that it runs ZKsync OS.
    function test_shutdownChain_zksyncOSChainCannotBeShutdown() public {
        vm.mockCall(chain, abi.encodeCall(IGetters.getZKsyncOS, ()), abi.encode(true));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainCannotBeShutdown.selector, chainId));
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    function test_shutdownChain_twiceReverts() public {
        _shutdown();
        vm.prank(governance);
        vm.expectRevert(ChainIsShutdown.selector);
        assetTracker.shutdownChain(chainId, distributorProxy);
    }

    /*//////////////////////////////////////////////////////////////
                    No new operations after shutdown
    //////////////////////////////////////////////////////////////*/

    function _requestDirect(uint256 _mintValue) internal {
        vm.deal(alice, _mintValue);
        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect({
            _chainId: chainId,
            _mintValue: _mintValue,
            _l2Value: 0,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: ""
        });
        vm.prank(alice);
        addresses.bridgehub.requestL2TransactionDirect{value: _mintValue}(request);
    }

    function test_denyAllFilterer_blocksL1ToL2Transactions() public {
        vm.prank(chainAdmin);
        IZKChain(chain).setTransactionFilterer(denyAllFilterer);
        vm.txGasPrice(GAS_PRICE);
        uint256 mintValue = _baseCost();
        vm.expectRevert(TransactionNotAllowed.selector);
        this.requestDirectExternal(mintValue);
    }

    function test_shutdown_blocksDeposits() public {
        _shutdown();
        vm.txGasPrice(GAS_PRICE);
        uint256 mintValue = _baseCost();
        // The base token deposit reaches the asset tracker before the transaction reaches the filterer.
        vm.expectRevert(ChainIsShutdown.selector);
        this.requestDirectExternal(mintValue);
    }

    /// @dev The asset tracker rejects any value sent to a shut down chain by itself, so no deposit of the base token
    /// or of an ERC20 goes through even if the governance later removes the filterer.
    function test_shutdown_blocksDepositsWithoutFilterer() public {
        _shutdown();
        vm.prank(governance);
        IZKChain(chain).setTransactionFilterer(address(0));

        vm.expectRevert(ChainIsShutdown.selector);
        this.depositEthExternal(alice);
        vm.expectRevert(ChainIsShutdown.selector);
        this.depositTokenExternal(bob, TOKEN_DEPOSIT);
    }

    /// @dev External wrappers, so that `vm.expectRevert` applies to the whole request.
    function requestDirectExternal(uint256 _mintValue) external {
        _requestDirect(_mintValue);
    }

    function depositEthExternal(address _user) external {
        _depositEth(_user);
    }

    function depositTokenExternal(address _user, uint256 _amount) external {
        _depositToken(_user, _amount);
    }

    function test_shutdown_blocksBatches() public {
        _shutdown();
        // The ValidatorTimelock is no longer a validator of the chain, so the chain rejects any batch it forwards.
        // The modifiers are checked before the calldata is decoded, so empty data is enough here.
        vm.startPrank(validatorTimelock);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validatorTimelock));
        ICommitter(chain).commitBatchesSharedBridge(chain, 1, 1, "");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validatorTimelock));
        IExecutor(chain).proveBatchesSharedBridge(chain, 1, 1, "");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validatorTimelock));
        IExecutor(chain).executeBatchesSharedBridge(chain, 1, 1, "");
        vm.stopPrank();
    }

    /// @dev Withdrawals from batches executed before the shutdown are in the snapshot, so they can no longer be
    /// finalized: that would pay them twice. Withdrawal finalization is a public flow, so it runs for real.
    function test_shutdown_blocksWithdrawals() public {
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: bob,
            _remoteReceiver: bob,
            _originToken: address(token),
            _amount: 1 ether,
            _erc20Metadata: ""
        });
        _mockMessageRootProofs();

        // Before the shutdown, a withdrawal is paid.
        _finalizeWithdrawal(0, tokenAssetId, transferData);
        assertEq(token.balanceOf(bob), 1 ether);

        _shutdown();

        // After it, the next one reverts.
        vm.expectRevert(ChainIsShutdown.selector);
        _finalizeWithdrawal(1, tokenAssetId, transferData);
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), TOKEN_DEPOSIT - 1 ether);
    }

    /// @dev Failed deposits are in the snapshot too, so they can no longer be claimed back.
    function test_shutdown_blocksFailedDepositClaims() public {
        bytes32 bobDepositTxHash = lastTokenDepositTxHash;
        _depositToken(bob, 1 ether);
        _mockMessageRootProofs();

        // Before the shutdown, a failed deposit is claimed back.
        _claimFailedTokenDeposit(lastTokenDepositTxHash, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);

        _shutdown();

        // After it, claiming the first deposit reverts.
        vm.expectRevert(ChainIsShutdown.selector);
        _claimFailedTokenDeposit(bobDepositTxHash, TOKEN_DEPOSIT);
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), TOKEN_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                        Distributor management
    //////////////////////////////////////////////////////////////*/

    /// @dev Replacing the distributor is a governance rescue operation; normally `shutdownChain` sets it.
    function test_setShutdownDistributor() public {
        address distributor = makeAddr("distributor");

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainNotShutdown.selector, chainId));
        assetTracker.setShutdownDistributor(chainId, distributor);

        _shutdown();

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        assetTracker.setShutdownDistributor(chainId, distributor);

        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        assetTracker.setShutdownDistributor(chainId, address(0));

        vm.expectEmit(true, true, false, false, address(assetTracker));
        emit IL1AssetTracker.ShutdownDistributorSet(chainId, distributor);
        vm.prank(governance);
        assetTracker.setShutdownDistributor(chainId, distributor);
        (address recordedChainAdmin, address recordedDistributor) = assetTracker.shutdownChainInfo(chainId);
        assertEq(recordedChainAdmin, chainAdmin);
        assertEq(recordedDistributor, distributor);
    }

    function test_sendShutdownChainFunds_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainNotShutdown.selector, chainId));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);

        _shutdown();
        // The distributor is still the installer, which has no `MERKLE_ROOT()`.
        vm.expectRevert(bytes(""));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);

        // A distributor initialized without a root is not accepted either.
        _installDistributor(bytes32(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ShutdownDistributorNotInitialized.selector, chainId));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);
    }

    /// @dev The vault releases the funds of a shut down chain only to the asset tracker, and not while it is paused.
    function test_transferShutdownChainFunds_guards() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        addresses.l1NativeTokenVault.transferShutdownChainFunds(ethAssetId, alice, 1);

        _shutdown();
        _deployDistributorForSnapshot();
        vm.prank(addresses.l1NativeTokenVault.owner());
        addresses.l1NativeTokenVault.pause();
        vm.expectRevert("Pausable: paused");
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, ethAssetId), ethDeposited);
    }

    /*//////////////////////////////////////////////////////////////
                    Full flow: shutdown -> distribute -> claim
    //////////////////////////////////////////////////////////////*/

    Merkle merkle;
    bytes32[] snapshotLeaves;

    /// @dev Snapshot of the final L2 state (computed off-chain): alice owns all the ETH, bob owns the tokens.
    function _deployDistributorForSnapshot() internal returns (IZkSyncLiteSunsetClaimDistributorL1 distributor) {
        snapshotLeaves.push(_leaf(0, alice, address(0), ethDeposited));
        snapshotLeaves.push(_leaf(1, bob, address(token), TOKEN_DEPOSIT));
        merkle = new Merkle();
        distributor = _installDistributor(merkle.getRoot(snapshotLeaves), block.timestamp);
    }

    function test_fullFlow_sendFundsToDistributorAndClaim() public {
        _shutdown();
        IZkSyncLiteSunsetClaimDistributorL1 distributor = _deployDistributorForSnapshot();

        uint256 ntvEthBefore = address(addresses.l1NativeTokenVault).balance;
        uint256 l1EthBalanceBefore = IAssetTrackerBase(address(assetTracker)).chainBalance(block.chainid, ethAssetId);

        // Anyone can push the funds to the distributor.
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, true, true, true, address(assetTracker));
        emit IL1AssetTracker.ShutdownChainFundsSent(chainId, ethAssetId, address(distributor), ethDeposited);
        vm.prank(anyone);
        assertEq(assetTracker.sendShutdownChainFunds(chainId, ethAssetId), ethDeposited);
        vm.prank(anyone);
        assertEq(assetTracker.sendShutdownChainFunds(chainId, tokenAssetId), TOKEN_DEPOSIT);

        assertEq(address(distributor).balance, ethDeposited);
        assertEq(token.balanceOf(address(distributor)), TOKEN_DEPOSIT);
        assertEq(address(addresses.l1NativeTokenVault).balance, ntvEthBefore - ethDeposited);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, ethAssetId), 0);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), 0);
        // Accounting-wise the funds moved to L1, like a withdrawal.
        assertEq(
            IAssetTrackerBase(address(assetTracker)).chainBalance(block.chainid, ethAssetId),
            l1EthBalanceBefore + ethDeposited
        );

        // Nothing left to send.
        vm.expectRevert(abi.encodeWithSelector(NoChainBalanceToSend.selector, chainId, ethAssetId));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);

        _claimAll(distributor, anyone);
    }

    function _claimAll(IZkSyncLiteSunsetClaimDistributorL1 _distributor, address _anyone) internal {
        // Alice claims herself.
        uint256 aliceBefore = alice.balance;
        bytes32[] memory proof0 = merkle.getProof(snapshotLeaves, 0);
        vm.prank(alice);
        _distributor.claim(0, address(0), ethDeposited, proof0);
        assertEq(alice.balance, aliceBefore + ethDeposited);
        assertTrue(_distributor.isClaimed(0));

        // A third party claims on behalf of bob; funds go to bob.
        bytes32[] memory proof1 = merkle.getProof(snapshotLeaves, 1);
        vm.prank(_anyone);
        _distributor.claimTo(1, bob, address(token), TOKEN_DEPOSIT, proof1);
        assertEq(token.balanceOf(bob), TOKEN_DEPOSIT);
        assertEq(token.balanceOf(address(_distributor)), 0);
        assertEq(address(_distributor).balance, 0);

        // Double claims are impossible.
        vm.prank(alice);
        vm.expectRevert(IZkSyncLiteSunsetClaimDistributorL1.ZkSyncLiteSunsetClaimDistributor__AlreadyClaimed.selector);
        _distributor.claim(0, address(0), ethDeposited, proof0);
    }

    /*//////////////////////////////////////////////////////////////
                    Tokens native to the shut down chain
    //////////////////////////////////////////////////////////////*/

    address constant L2_NATIVE_TOKEN = address(0x1234);
    uint256 constant WITHDRAWN_BEFORE_SHUTDOWN = 3 ether;
    uint256 constant HELD_ON_L2_AT_SHUTDOWN = 7 ether;

    /// @dev Finalizes on L1 a withdrawal of a token native to the chain, which deploys its L1 representation and
    /// registers it in the asset tracker.
    function _withdrawChainNativeToken(address _receiver, uint256 _amount) internal returns (bytes32 assetId) {
        assetId = DataEncoding.encodeNTVAssetId(chainId, L2_NATIVE_TOKEN);
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _receiver,
            _remoteReceiver: _receiver,
            _originToken: L2_NATIVE_TOKEN,
            _amount: _amount,
            _erc20Metadata: DataEncoding.encodeTokenData(
                chainId,
                abi.encode("L2 Token"),
                abi.encode("L2T"),
                abi.encode(uint8(18))
            )
        });
        _mockMessageRootProofs();
        _finalizeWithdrawal(0, assetId, transferData);
        vm.clearMockedCalls();
    }

    function test_chainNativeAsset_fullFlow() public {
        bytes32 nativeAssetId = _withdrawChainNativeToken(alice, WITHDRAWN_BEFORE_SHUTDOWN);
        IERC20 l1Token = IERC20(addresses.l1NativeTokenVault.tokenAddress(nativeAssetId));
        assertEq(l1Token.balanceOf(alice), WITHDRAWN_BEFORE_SHUTDOWN);
        uint256 chainBalanceBefore = IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, nativeAssetId);

        _shutdown();

        // Snapshot: bob held the whole remaining L2 supply.
        snapshotLeaves.push(_leaf(0, bob, address(l1Token), HELD_ON_L2_AT_SHUTDOWN));
        // Murky needs at least two leaves; a zero claim for alice fills the tree.
        snapshotLeaves.push(_leaf(1, alice, address(0), 0));
        merkle = new Merkle();
        IZkSyncLiteSunsetClaimDistributorL1 distributor = _installDistributor(
            merkle.getRoot(snapshotLeaves),
            block.timestamp
        );

        // The chain admin mints to the distributor what was still held on L2 at shutdown.
        vm.expectEmit(true, true, true, true, address(assetTracker));
        emit IL1AssetTracker.ShutdownChainFundsSent(
            chainId,
            nativeAssetId,
            address(distributor),
            HELD_ON_L2_AT_SHUTDOWN
        );
        vm.prank(chainAdmin);
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);
        assertTrue(assetTracker.isShutdownChainNativeAssetMinted(chainId, nativeAssetId));

        // The remaining L2 supply is minted on L1 to the distributor, on top of what was withdrawn before.
        assertEq(l1Token.balanceOf(address(distributor)), HELD_ON_L2_AT_SHUTDOWN);
        assertEq(l1Token.totalSupply(), WITHDRAWN_BEFORE_SHUTDOWN + HELD_ON_L2_AT_SHUTDOWN);
        assertEq(
            IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, nativeAssetId),
            chainBalanceBefore - HELD_ON_L2_AT_SHUTDOWN
        );

        // It can only be minted once.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ShutdownChainNativeAssetAlreadyMinted.selector, chainId, nativeAssetId));
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, 1);

        // Bob claims the token from the distributor.
        bytes32[] memory proof = merkle.getProof(snapshotLeaves, 0);
        vm.prank(bob);
        distributor.claim(0, address(l1Token), HELD_ON_L2_AT_SHUTDOWN, proof);
        assertEq(l1Token.balanceOf(bob), HELD_ON_L2_AT_SHUTDOWN);
        assertEq(l1Token.balanceOf(address(distributor)), 0);
    }

    function test_mintShutdownChainNativeAsset_reverts() public {
        bytes32 nativeAssetId = _withdrawChainNativeToken(alice, WITHDRAWN_BEFORE_SHUTDOWN);

        // Not shut down yet: there is no chain admin of record.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        _shutdown();

        // Only the chain admin of record, not the governance.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        // Only for tokens native to the chain: L1 tokens are swept from the chain's L1 balance instead.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotShutdownChainNativeAsset.selector, chainId, tokenAssetId));
        assetTracker.mintShutdownChainNativeAsset(chainId, tokenAssetId, HELD_ON_L2_AT_SHUTDOWN);

        // The distributor is still the installer, which has no `MERKLE_ROOT()`.
        vm.prank(chainAdmin);
        vm.expectRevert(bytes(""));
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        _installDistributor(keccak256("root"), block.timestamp);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(NoChainBalanceToSend.selector, chainId, nativeAssetId));
        assetTracker.mintShutdownChainNativeAsset(chainId, nativeAssetId, 0);
        assertFalse(assetTracker.isShutdownChainNativeAssetMinted(chainId, nativeAssetId));

        // Tokens native to the chain have no L1 balance to send: only the chain admin can mint them.
        vm.expectRevert(abi.encodeWithSelector(ShutdownChainNativeAsset.selector, chainId, nativeAssetId));
        assetTracker.sendShutdownChainFunds(chainId, nativeAssetId);
    }

    /*//////////////////////////////////////////////////////////////
                        Distributor unhappy paths
    //////////////////////////////////////////////////////////////*/

    function test_distributor_invalidProofWindowAndPause() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(0, alice, address(0), 1 ether);
        leaves[1] = _leaf(1, bob, address(token), 2 ether);
        Merkle merkle = new Merkle();
        IZkSyncLiteSunsetClaimDistributorL1 distributor = _deployDistributor(
            merkle.getRoot(leaves),
            block.timestamp + 1 days
        );
        vm.deal(address(distributor), 1 ether);
        bytes32[] memory proof0 = merkle.getProof(leaves, 0);

        // Window not open yet.
        vm.prank(alice);
        vm.expectRevert(
            IZkSyncLiteSunsetClaimDistributorL1.ZkSyncLiteSunsetClaimDistributor__ClaimWindowNotOpen.selector
        );
        distributor.claim(0, address(0), 1 ether, proof0);

        vm.warp(block.timestamp + 1 days);

        // Wrong amount -> invalid proof.
        vm.prank(alice);
        vm.expectRevert(IZkSyncLiteSunsetClaimDistributorL1.ZkSyncLiteSunsetClaimDistributor__InvalidProof.selector);
        distributor.claim(0, address(0), 2 ether, proof0);

        // Another caller cannot redirect alice's claim to themselves via `claim`.
        vm.prank(bob);
        vm.expectRevert(IZkSyncLiteSunsetClaimDistributorL1.ZkSyncLiteSunsetClaimDistributor__InvalidProof.selector);
        distributor.claim(0, address(0), 1 ether, proof0);

        // Paused by the owner.
        vm.prank(distributorOwner);
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        distributor.claim(0, address(0), 1 ether, proof0);

        vm.prank(distributorOwner);
        distributor.unpause();
        vm.prank(alice);
        distributor.claim(0, address(0), 1 ether, proof0);
        assertTrue(distributor.isClaimed(0));
        assertFalse(distributor.isClaimed(1));
    }

    /*//////////////////////////////////////////////////////////////
                        Distributor installer
    //////////////////////////////////////////////////////////////*/

    /// @dev Only the chain admin can install the distributor, only after the shutdown, only once and only the pinned
    /// implementation. After that, only the governance (the proxy admin) can upgrade the distributor.
    function test_installer_installOnceByChainAdmin() public {
        bytes32 root = keccak256("root");
        ShutdownDistributorInstaller installer = ShutdownDistributorInstaller(distributorProxy);
        assertEq(address(installer.L1_ASSET_TRACKER()), address(assetTracker));
        assertEq(installer.CHAIN_ID(), chainId);
        assertEq(installer.CHAIN_ADMIN(), chainAdmin);
        assertEq(installer.DISTRIBUTOR_IMPLEMENTATION(), distributorImplementation);

        // The root must commit to the final state of the chain, which only exists after the shutdown.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidShutdownDistributor.selector, chainId, distributorProxy));
        installer.install(root, block.timestamp, distributorOwner);

        _shutdown();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bob));
        installer.install(root, block.timestamp, distributorOwner);

        // The proxy admin can not reach the implementation at all.
        vm.prank(governance);
        vm.expectRevert("TransparentUpgradeableProxy: admin cannot fallback to proxy target");
        installer.install(root, block.timestamp, distributorOwner);

        vm.expectEmit(true, false, false, false, distributorProxy);
        emit IERC1967.Upgraded(distributorImplementation);
        vm.prank(chainAdmin);
        installer.install(root, block.timestamp, distributorOwner);
        assertEq(IZkSyncLiteSunsetClaimDistributorL1(distributorProxy).MERKLE_ROOT(), root);
        assertEq(IZkSyncLiteSunsetClaimDistributorL1(distributorProxy).WINDOW_START(), block.timestamp);
        // The installed implementation is the pinned one, and the governance is still the proxy admin.
        vm.prank(governance);
        assertEq(ITransparentUpgradeableProxy(distributorProxy).implementation(), distributorImplementation);
        vm.prank(governance);
        assertEq(ITransparentUpgradeableProxy(distributorProxy).admin(), governance);

        // The installer is gone: `install` is not a function of the distributor.
        vm.prank(chainAdmin);
        vm.expectRevert();
        installer.install(keccak256("other root"), block.timestamp, chainAdmin);

        // The chain admin is not the proxy admin, so its upgrade call reaches the distributor, which has no such
        // function.
        address newImpl = deployCode(DISTRIBUTOR_ARTIFACT);
        vm.prank(chainAdmin);
        vm.expectRevert();
        ITransparentUpgradeableProxy(distributorProxy).upgradeTo(newImpl);

        // The governance can still replace the distributor, e.g. in a rescue.
        vm.prank(governance);
        ITransparentUpgradeableProxy(distributorProxy).upgradeTo(newImpl);
        vm.prank(governance);
        assertEq(ITransparentUpgradeableProxy(distributorProxy).implementation(), newImpl);
    }

    /// @dev Once the governance replaces the distributor, the old proxy can no longer be installed.
    function test_installer_rejectsReplacedDistributor() public {
        _shutdown();
        vm.prank(governance);
        assetTracker.setShutdownDistributor(chainId, makeAddr("newDistributor"));

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidShutdownDistributor.selector, chainId, distributorProxy));
        ShutdownDistributorInstaller(distributorProxy).install(keccak256("root"), block.timestamp, distributorOwner);
    }

    function test_installer_zeroAddressesRevert() public {
        vm.expectRevert(ZeroAddress.selector);
        new ShutdownDistributorInstaller(IL1AssetTracker(address(0)), chainId, chainAdmin, distributorImplementation);
        vm.expectRevert(ZeroAddress.selector);
        new ShutdownDistributorInstaller(assetTracker, chainId, address(0), distributorImplementation);
        vm.expectRevert(ZeroAddress.selector);
        new ShutdownDistributorInstaller(assetTracker, chainId, chainAdmin, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            Upgrade script
    //////////////////////////////////////////////////////////////*/

    string constant UPGRADE_OUTPUT =
        "/test/foundry/l1/integration/deploy-scripts/script-out/chain-shutdown-upgrade.toml";

    /// @dev The ecosystem upgrade that adds the shutdown: the script deploys the new implementations and the deny-all
    /// filterer, and the governance executes the calls from its output. The proxies keep their state, and a chain can
    /// then be shut down through them.
    function test_upgradeScript() public {
        address nativeTokenVault = address(addresses.l1NativeTokenVault);
        address wethToken = address(addresses.l1NativeTokenVault.WETH_TOKEN());
        vm.setEnv("CHAIN_SHUTDOWN_UPGRADE_OUTPUT", UPGRADE_OUTPUT);
        new ChainShutdownUpgradeForTests().run(address(addresses.bridgehub));

        string memory toml = vm.readFile(string.concat(vm.projectRoot(), UPGRADE_OUTPUT));
        address[2] memory proxies = [address(assetTracker), nativeTokenVault];
        address[2] memory implementations = [
            toml.readAddress("$.l1_asset_tracker_implementation_addr"),
            toml.readAddress("$.l1_native_token_vault_implementation_addr")
        ];
        address filterer = toml.readAddress("$.deny_all_transaction_filterer_addr");
        Call[] memory calls = abi.decode(toml.readBytes("$.governance_calls"), (Call[]));

        assertEq(calls.length, 2);
        for (uint256 i = 0; i < calls.length; ++i) {
            ProxyAdmin proxyAdmin = ProxyAdmin(calls[i].target);
            assertTrue(
                proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(proxies[i])) != implementations[i]
            );
            vm.expectEmit(true, false, false, false, proxies[i]);
            emit IERC1967.Upgraded(implementations[i]);
            vm.prank(proxyAdmin.owner());
            (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            assertTrue(success);
            assertEq(proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(proxies[i])), implementations[i]);
        }

        // The new implementations have the same immutables.
        L1AssetTracker upgradedAssetTracker = L1AssetTracker(address(assetTracker));
        assertEq(address(upgradedAssetTracker.BRIDGE_HUB()), address(addresses.bridgehub));
        assertEq(address(upgradedAssetTracker.NATIVE_TOKEN_VAULT()), nativeTokenVault);
        assertEq(address(upgradedAssetTracker.MESSAGE_ROOT()), address(addresses.bridgehub.messageRoot()));
        assertEq(address(addresses.l1NativeTokenVault.WETH_TOKEN()), wethToken);
        assertEq(address(addresses.l1NativeTokenVault.ASSET_ROUTER()), address(addresses.sharedBridge));
        assertEq(address(addresses.l1NativeTokenVault.L1_NULLIFIER()), address(addresses.l1Nullifier));
        // The proxies keep their state.
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, ethAssetId), ethDeposited);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), TOKEN_DEPOSIT);
        assertEq(Ownable2StepUpgradeable(address(assetTracker)).owner(), governance);
        assertEq(address(addresses.l1NativeTokenVault.l1AssetTracker()), address(assetTracker));
        assertEq(addresses.l1NativeTokenVault.tokenAddress(tokenAssetId), address(token));

        // A chain can be shut down through the upgraded proxies, with the filterer that the script deployed.
        denyAllFilterer = filterer;
        _shutdown();
        assertTrue(assetTracker.isChainShutdown(chainId));
        assertEq(IZKChain(chain).getTransactionFilterer(), filterer);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
