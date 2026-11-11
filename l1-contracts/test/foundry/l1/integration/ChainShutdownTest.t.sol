// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Merkle} from "murky/Merkle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {ShutdownInformation} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IZkSyncLiteSunsetClaimDistributorL1} from "./utils/IZkSyncLiteSunsetClaimDistributorL1.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IMessageRootBase, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {ChainIsShutdown, ChainShutdownAlreadyApproved, ChainShutdownNotApproved, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {ChainNotShutdown, NoChainBalanceToSend, NotShutdownChainNativeAsset, ShutdownChainNativeAssetAmountAlreadySet, ShutdownDistributorNotSet} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";

/// @notice End-to-end tests of the chain shutdown flow on L1:
/// two-party approval -> chain is frozen forever -> its L1 funds are sent to a Merkle distributor -> users claim.
/// @dev Uses the full L1 ecosystem deployment and real deposits through the Bridgehub, no storage overrides.
contract ChainShutdownTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    uint256 constant GAS_PRICE = 10_000_000;
    uint256 constant L2_GAS_LIMIT = 1_000_000;
    uint256 constant TOKEN_DEPOSIT = 5 ether;

    uint256 chainId;
    address chain;
    address chainAdmin;
    address ctmOwner;
    IL1AssetTracker assetTracker;
    address assetTrackerOwner;

    TestnetERC20Token token;
    bytes32 ethAssetId;
    bytes32 tokenAssetId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 ethDeposited;

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
        assetTrackerOwner = Ownable2StepUpgradeable(address(assetTracker)).owner();

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
        addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(request);
    }

    function _shutdown() internal {
        vm.prank(chainAdmin);
        IZKChain(chain).approveShutdown();
        vm.prank(ctmOwner);
        addresses.chainTypeManager.approveChainShutdown(chainId);
    }

    function _leaf(uint256 _index, address _claimant, address _token, uint256 _amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_index, _claimant, _token, _amount));
    }

    /// @dev The distributor is the unchanged, audited ZKsync Lite sunset distributor. It is built with the upstream
    /// compiler settings in `vendor/zksync-lite-sunset`, so it is deployed from that artifact.
    string constant DISTRIBUTOR_ARTIFACT =
        "vendor/zksync-lite-sunset/out/ZkSyncLiteSunsetClaimDistributorL1.sol/ZkSyncLiteSunsetClaimDistributorL1.json";

    function _deployDistributor(
        bytes32 _root,
        uint256 _windowStart
    ) internal returns (IZkSyncLiteSunsetClaimDistributorL1) {
        address impl = deployCode(DISTRIBUTOR_ARTIFACT);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            impl,
            makeAddr("distributorProxyAdmin"),
            abi.encodeCall(IZkSyncLiteSunsetClaimDistributorL1.initialize, (_root, _windowStart, assetTrackerOwner))
        );
        return IZkSyncLiteSunsetClaimDistributorL1(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                        Two-party approval
    //////////////////////////////////////////////////////////////*/

    function test_depositsAreTrackedForTheChain() public view {
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, ethAssetId), ethDeposited);
        assertEq(IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, tokenAssetId), TOKEN_DEPOSIT);
    }

    function test_shutdown_adminThenGovernance() public {
        vm.expectEmit(true, false, false, false, chain);
        emit IAdmin.ShutdownApproved(chainAdmin);
        vm.prank(chainAdmin);
        IZKChain(chain).approveShutdown();

        // A single approval does not shut the chain down.
        assertFalse(IZKChain(chain).isShutdown());
        assertFalse(assetTracker.isChainShutdown(chainId));
        ShutdownInformation memory info = IZKChain(chain).getShutdownInfo();
        assertTrue(info.approvedByAdmin);
        assertFalse(info.approvedByChainTypeManager);

        uint256 lastExecuted = IZKChain(chain).getTotalBatchesExecuted();
        vm.expectEmit(true, false, false, false, address(assetTracker));
        emit IL1AssetTracker.ChainShutdownRegistered(chainId);
        vm.expectEmit(false, false, false, true, chain);
        emit IAdmin.ChainShutdown(lastExecuted);
        vm.prank(ctmOwner);
        addresses.chainTypeManager.approveChainShutdown(chainId);

        assertTrue(IZKChain(chain).isShutdown());
        assertTrue(assetTracker.isChainShutdown(chainId));
        info = IZKChain(chain).getShutdownInfo();
        assertTrue(info.activated);
        assertEq(info.lastExecutedBatch, lastExecuted);
        // All non-executed batches are reverted at shutdown.
        assertEq(IZKChain(chain).getTotalBatchesCommitted(), lastExecuted);
    }

    function test_shutdown_governanceThenAdmin() public {
        vm.prank(ctmOwner);
        addresses.chainTypeManager.approveChainShutdown(chainId);
        assertFalse(IZKChain(chain).isShutdown());
        assertTrue(IZKChain(chain).getShutdownInfo().approvedByChainTypeManager);

        vm.prank(chainAdmin);
        IZKChain(chain).approveShutdown();
        assertTrue(IZKChain(chain).isShutdown());
        assertTrue(assetTracker.isChainShutdown(chainId));
    }

    function test_approveShutdown_unauthorized() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        IZKChain(chain).approveShutdown();

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        addresses.chainTypeManager.approveChainShutdown(chainId);
    }

    function test_approveShutdown_twiceReverts() public {
        vm.startPrank(chainAdmin);
        IZKChain(chain).approveShutdown();
        vm.expectRevert(ChainShutdownAlreadyApproved.selector);
        IZKChain(chain).approveShutdown();
        vm.stopPrank();
    }

    function test_revokeShutdownApproval() public {
        vm.prank(chainAdmin);
        IZKChain(chain).approveShutdown();

        vm.expectEmit(true, false, false, false, chain);
        emit IAdmin.ShutdownApprovalRevoked(chainAdmin);
        vm.prank(chainAdmin);
        IZKChain(chain).revokeShutdownApproval();
        assertFalse(IZKChain(chain).getShutdownInfo().approvedByAdmin);

        // Governance approval alone now does not shut the chain down.
        vm.prank(ctmOwner);
        addresses.chainTypeManager.approveChainShutdown(chainId);
        assertFalse(IZKChain(chain).isShutdown());

        vm.prank(ctmOwner);
        addresses.chainTypeManager.revokeChainShutdownApproval(chainId);
        assertFalse(IZKChain(chain).getShutdownInfo().approvedByChainTypeManager);

        // Revoking a non-existent approval reverts.
        vm.prank(chainAdmin);
        vm.expectRevert(ChainShutdownNotApproved.selector);
        IZKChain(chain).revokeShutdownApproval();
    }

    function test_shutdown_isIrreversible() public {
        _shutdown();

        vm.prank(chainAdmin);
        vm.expectRevert(ChainIsShutdown.selector);
        IZKChain(chain).revokeShutdownApproval();

        vm.prank(ctmOwner);
        vm.expectRevert(ChainIsShutdown.selector);
        addresses.chainTypeManager.revokeChainShutdownApproval(chainId);

        vm.prank(chainAdmin);
        vm.expectRevert(ChainIsShutdown.selector);
        IZKChain(chain).approveShutdown();

        assertTrue(IZKChain(chain).isShutdown());
    }

    /*//////////////////////////////////////////////////////////////
                    No new operations after shutdown
    //////////////////////////////////////////////////////////////*/

    function test_shutdown_blocksDeposits() public {
        _shutdown();

        vm.txGasPrice(GAS_PRICE);
        uint256 mintValue = _baseCost();
        vm.deal(alice, mintValue);
        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect({
            _chainId: chainId,
            _mintValue: mintValue,
            _l2Value: 0,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: ""
        });
        vm.prank(alice);
        vm.expectRevert(ChainIsShutdown.selector);
        addresses.bridgehub.requestL2TransactionDirect{value: mintValue}(request);
    }

    function test_shutdown_blocksBatchesUpgradesAndMigration() public {
        address validator = makeAddr("validator");
        vm.prank(ctmOwner);
        addresses.chainTypeManager.setValidator(chainId, validator, true);

        _shutdown();

        // The modifiers are checked before the calldata is decoded, so empty data is enough here.
        vm.startPrank(validator);
        vm.expectRevert(ChainIsShutdown.selector);
        ICommitter(chain).commitBatchesSharedBridge(chain, 1, 1, "");
        vm.expectRevert(ChainIsShutdown.selector);
        IExecutor(chain).proveBatchesSharedBridge(chain, 1, 1, "");
        vm.expectRevert(ChainIsShutdown.selector);
        IExecutor(chain).executeBatchesSharedBridge(chain, 1, 1, "");
        vm.stopPrank();

        Diamond.DiamondCutData memory emptyCut;
        uint256 protocolVersion = IZKChain(chain).getProtocolVersion();
        vm.prank(chainAdmin);
        vm.expectRevert(ChainIsShutdown.selector);
        IZKChain(chain).upgradeChainFromVersion(chain, protocolVersion, emptyCut);

        vm.prank(chainAdmin);
        vm.expectRevert(ChainIsShutdown.selector);
        IMigrator(chain).pauseDepositsBeforeInitiatingMigration();
    }

    function test_shutdown_blocksWithdrawalAccounting() public {
        _shutdown();
        // Isolated check of the L1AssetTracker hook: we call it as the NTV directly, since producing a real
        // withdrawal would require an executed batch, which is impossible after the shutdown anyway.
        vm.prank(address(addresses.l1NativeTokenVault));
        vm.expectRevert(ChainIsShutdown.selector);
        assetTracker.handleChainBalanceDecreaseOnL1(chainId, ethAssetId, 1);
    }

    function test_registerChainShutdown_onlyChain() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        assetTracker.registerChainShutdown(chainId);
    }

    /*//////////////////////////////////////////////////////////////
                        Distributor management
    //////////////////////////////////////////////////////////////*/

    function test_setShutdownDistributor() public {
        address distributor = makeAddr("distributor");

        vm.prank(assetTrackerOwner);
        vm.expectRevert(abi.encodeWithSelector(ChainNotShutdown.selector, chainId));
        assetTracker.setShutdownDistributor(chainId, distributor);

        _shutdown();

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        assetTracker.setShutdownDistributor(chainId, distributor);

        vm.prank(assetTrackerOwner);
        vm.expectRevert(ZeroAddress.selector);
        assetTracker.setShutdownDistributor(chainId, address(0));

        vm.expectEmit(true, true, false, false, address(assetTracker));
        emit IL1AssetTracker.ShutdownDistributorSet(chainId, distributor);
        vm.prank(assetTrackerOwner);
        assetTracker.setShutdownDistributor(chainId, distributor);
        assertEq(assetTracker.shutdownDistributor(chainId), distributor);
    }

    function test_sendShutdownChainFunds_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainNotShutdown.selector, chainId));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);

        _shutdown();
        vm.expectRevert(abi.encodeWithSelector(ShutdownDistributorNotSet.selector, chainId));
        assetTracker.sendShutdownChainFunds(chainId, ethAssetId);
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
        distributor = _deployDistributor(merkle.getRoot(snapshotLeaves), block.timestamp);
    }

    function test_fullFlow_sendFundsToDistributorAndClaim() public {
        _shutdown();
        IZkSyncLiteSunsetClaimDistributorL1 distributor = _deployDistributorForSnapshot();

        vm.prank(assetTrackerOwner);
        assetTracker.setShutdownDistributor(chainId, address(distributor));

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
    /// registers it in the asset tracker. The Merkle proof of the L2 -> L1 message (`proveL2MessageInclusionShared` and
    /// `getProofData`) is mocked: this test is isolated from the message-root proof verification, everything after it (L1Nullifier, AssetRouter, NTV, asset tracker)
    /// runs for real.
    function _withdrawChainNativeToken(address _receiver, uint256 _amount) internal returns (bytes32 assetId) {
        vm.mockCall(
            address(addresses.bridgehub.messageRoot()),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        // The chain settles directly on L1, so the proof has no settlement-layer part (`settlementLayerChainId == 0`).
        ProofData memory proofData;
        vm.mockCall(
            address(addresses.bridgehub.messageRoot()),
            abi.encodeWithSelector(IMessageRootBase.getProofData.selector),
            abi.encode(proofData)
        );
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
        addresses.l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: chainId,
                l2BatchNumber: 0,
                l2MessageIndex: 0,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: 0,
                message: abi.encodePacked(AssetRouterBase.finalizeDeposit.selector, chainId, assetId, transferData),
                merkleProof: new bytes32[](0)
            })
        );
        vm.clearMockedCalls();
    }

    function test_chainNativeAsset_fullFlow() public {
        bytes32 nativeAssetId = _withdrawChainNativeToken(alice, WITHDRAWN_BEFORE_SHUTDOWN);
        IERC20 l1Token = IERC20(addresses.l1NativeTokenVault.tokenAddress(nativeAssetId));
        assertEq(l1Token.balanceOf(alice), WITHDRAWN_BEFORE_SHUTDOWN);
        uint256 chainBalanceBefore = IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, nativeAssetId);

        _shutdown();

        // The chain admin declares how much of the token was still held on L2 at shutdown.
        vm.expectEmit(true, true, false, true, address(assetTracker));
        emit IL1AssetTracker.ShutdownChainNativeAssetAmountSet(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);
        vm.prank(chainAdmin);
        IZKChain(chain).setShutdownChainNativeAssetAmount(nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);
        assertEq(assetTracker.shutdownChainNativeAssetAmount(chainId, nativeAssetId), HELD_ON_L2_AT_SHUTDOWN);
        assertTrue(assetTracker.isShutdownChainNativeAssetAmountSet(chainId, nativeAssetId));

        // Snapshot: bob held the whole remaining L2 supply.
        snapshotLeaves.push(_leaf(0, bob, address(l1Token), HELD_ON_L2_AT_SHUTDOWN));
        // Murky needs at least two leaves; a zero claim for alice fills the tree.
        snapshotLeaves.push(_leaf(1, alice, address(0), 0));
        merkle = new Merkle();
        IZkSyncLiteSunsetClaimDistributorL1 distributor = _deployDistributor(
            merkle.getRoot(snapshotLeaves),
            block.timestamp
        );
        vm.prank(assetTrackerOwner);
        assetTracker.setShutdownDistributor(chainId, address(distributor));

        vm.expectEmit(true, true, true, true, address(assetTracker));
        emit IL1AssetTracker.ShutdownChainFundsSent(
            chainId,
            nativeAssetId,
            address(distributor),
            HELD_ON_L2_AT_SHUTDOWN
        );
        assertEq(assetTracker.sendShutdownChainFunds(chainId, nativeAssetId), HELD_ON_L2_AT_SHUTDOWN);

        // The remaining L2 supply is minted on L1 to the distributor, on top of what was withdrawn before.
        assertEq(l1Token.balanceOf(address(distributor)), HELD_ON_L2_AT_SHUTDOWN);
        assertEq(l1Token.totalSupply(), WITHDRAWN_BEFORE_SHUTDOWN + HELD_ON_L2_AT_SHUTDOWN);
        assertEq(
            IAssetTrackerBase(address(assetTracker)).chainBalance(chainId, nativeAssetId),
            chainBalanceBefore - HELD_ON_L2_AT_SHUTDOWN
        );
        assertEq(assetTracker.shutdownChainNativeAssetAmount(chainId, nativeAssetId), 0);

        // It can only be sent once, and the amount can not be set again.
        vm.expectRevert(abi.encodeWithSelector(NoChainBalanceToSend.selector, chainId, nativeAssetId));
        assetTracker.sendShutdownChainFunds(chainId, nativeAssetId);
        vm.prank(chainAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ShutdownChainNativeAssetAmountAlreadySet.selector, chainId, nativeAssetId)
        );
        IZKChain(chain).setShutdownChainNativeAssetAmount(nativeAssetId, 1);

        // Bob claims the token from the distributor.
        bytes32[] memory proof = merkle.getProof(snapshotLeaves, 0);
        vm.prank(bob);
        distributor.claim(0, address(l1Token), HELD_ON_L2_AT_SHUTDOWN, proof);
        assertEq(l1Token.balanceOf(bob), HELD_ON_L2_AT_SHUTDOWN);
        assertEq(l1Token.balanceOf(address(distributor)), 0);
    }

    function test_setShutdownChainNativeAssetAmount_reverts() public {
        bytes32 nativeAssetId = _withdrawChainNativeToken(alice, WITHDRAWN_BEFORE_SHUTDOWN);

        // Not shut down yet.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainNotShutdown.selector, chainId));
        IZKChain(chain).setShutdownChainNativeAssetAmount(nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        _shutdown();

        // Only the chain admin.
        vm.prank(ctmOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ctmOwner));
        IZKChain(chain).setShutdownChainNativeAssetAmount(nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        // Only through the chain's diamond proxy.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
        assetTracker.setShutdownChainNativeAssetAmount(chainId, nativeAssetId, HELD_ON_L2_AT_SHUTDOWN);

        // Only for tokens native to the chain: L1 tokens are swept from the chain's L1 balance instead.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotShutdownChainNativeAsset.selector, chainId, tokenAssetId));
        IZKChain(chain).setShutdownChainNativeAssetAmount(tokenAssetId, HELD_ON_L2_AT_SHUTDOWN);

        // Without a declared amount there is nothing to send for a chain-native token.
        vm.prank(assetTrackerOwner);
        assetTracker.setShutdownDistributor(chainId, makeAddr("distributor"));
        vm.expectRevert(abi.encodeWithSelector(NoChainBalanceToSend.selector, chainId, nativeAssetId));
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
        vm.prank(assetTrackerOwner);
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        distributor.claim(0, address(0), 1 ether, proof0);

        vm.prank(assetTrackerOwner);
        distributor.unpause();
        vm.prank(alice);
        distributor.claim(0, address(0), 1 ether, proof0);
        assertTrue(distributor.isClaimed(0));
        assertFalse(distributor.isClaimed(1));
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
