// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IMessageRootBase, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {TransactionNotAllowed} from "contracts/common/L1ContractErrors.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IL2SharedBridgeLegacyFunctions} from "contracts/bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EraMaintenanceTransactionFilterer} from "contracts/transactionFilterer/EraMaintenanceTransactionFilterer.sol";
import {CallMode} from "contracts/transactionFilterer/interfaces/IEraMaintenanceTransactionFilterer.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

/// @dev Sends real deposits to a chain whose Mailbox uses the filterer, so the filterer decodes the calldata the
/// Era L1 asset router builds rather than calldata assembled by the test: the legacy `finalizeDeposit` for
/// L1-native tokens (through the Bridgehub or `L1ERC20Bridge`) and the new one for a token bridged back from L2.
contract EraMaintenanceTransactionFiltererIntegrationTest is
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer,
    L2TxMocker
{
    using LogFinder for Vm.Log[];

    uint256 internal constant MINT_VALUE = 250000000000100;
    uint256 internal constant L2_GAS_LIMIT = 1000000;
    uint256 internal constant TOKEN_CAP = 1000;
    uint256 internal constant STUCK_ETH = 100 ether;

    EraMaintenanceTransactionFilterer internal filterer;
    TestnetERC20Token internal token;
    bytes32 internal tokenAssetId;
    bytes32 internal baseTokenAssetId;
    address internal chainAdmin;
    address internal user = makeAddr("user");

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();

        // Same environment mocks as `AssetRouterIntegrationTest`: the deposit path queries migration state that
        // a freshly deployed ecosystem does not have.
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );

        token = TestnetERC20Token(tokens[1]);
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        baseTokenAssetId = addresses.bridgehub.baseTokenAssetId(eraZKChainId);

        EraMaintenanceTransactionFilterer implementation = new EraMaintenanceTransactionFilterer(
            IBridgehubBase(address(addresses.bridgehub))
        );
        address chainAddress = getZKChainAddress(eraZKChainId);
        chainAdmin = IZKChain(chainAddress).getAdmin();
        filterer = EraMaintenanceTransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(EraMaintenanceTransactionFilterer.initialize, (chainAdmin, eraZKChainId))
                )
            )
        );
        vm.prank(chainAdmin);
        IAdmin(chainAddress).setTransactionFilterer(address(filterer));

        bytes32[] memory assetIds = new bytes32[](1);
        assetIds[0] = tokenAssetId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = TOKEN_CAP;
        vm.prank(chainAdmin);
        filterer.setDepositCaps(assetIds, caps);
    }

    /// @dev Funds `user` and approves the native token vault, then returns the two-bridges request.
    function _prepareTokenDeposit(uint256 _amount) internal returns (L2TransactionRequestTwoBridgesOuter memory) {
        token.mint(user, _amount);
        return _prepareL1TokenDeposit(IERC20(address(token)), tokenAssetId, _amount);
    }

    /// @dev Funds `user` with the fee and approves the native token vault, then returns the two-bridges request.
    function _prepareL1TokenDeposit(
        IERC20 _l1Token,
        bytes32 _assetId,
        uint256 _amount
    ) internal returns (L2TransactionRequestTwoBridgesOuter memory) {
        vm.deal(user, MINT_VALUE);
        vm.prank(user);
        _l1Token.approve(address(addresses.l1NativeTokenVault), _amount);
        return
            L2TransactionRequestTwoBridgesOuter({
                chainId: eraZKChainId,
                mintValue: MINT_VALUE,
                l2Value: 0,
                l2GasLimit: L2_GAS_LIMIT,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                refundRecipient: address(0),
                secondBridgeAddress: address(addresses.sharedBridge),
                secondBridgeValue: 0,
                secondBridgeCalldata: bytes.concat(
                    NEW_ENCODING_VERSION,
                    abi.encode(_assetId, abi.encode(_amount, user, address(_l1Token)))
                )
            });
    }

    function _depositToken(uint256 _amount) internal returns (bytes32) {
        L2TransactionRequestTwoBridgesOuter memory request = _prepareTokenDeposit(_amount);
        vm.prank(user);
        return addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);
    }

    function _depositBaseToken(uint256 _l2Value) internal returns (bytes32) {
        vm.deal(user, MINT_VALUE + _l2Value);
        vm.prank(user);
        return
            addresses.bridgehub.requestL2TransactionDirect{value: MINT_VALUE + _l2Value}(
                L2TransactionRequestDirect({
                    chainId: eraZKChainId,
                    mintValue: MINT_VALUE + _l2Value,
                    l2Contract: user,
                    l2Value: _l2Value,
                    l2Calldata: hex"",
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                    factoryDeps: new bytes[](0),
                    refundRecipient: address(0)
                })
            );
    }

    /// @dev Withdraws `_amount` of a token native to the chain to `user` on L1, so the L1 native token vault
    /// deploys its bridged counterpart, and returns that counterpart and the token's asset id.
    function _withdrawL2NativeToken(uint256 _amount) internal returns (IERC20 l1Token, bytes32 assetId) {
        // Mocked because no batch with this withdrawal is committed on L1: the test needs the bridged token, not
        // the proof of its withdrawal. The chain settles on L1.
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageRootBase.getProofData.selector),
            abi.encode(
                ProofData({
                    settlementLayerChainId: block.chainid,
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 0,
                    batchLeafProofLen: 0,
                    batchSettlementRoot: 0,
                    chainIdLeaf: 0,
                    ptr: 0,
                    finalProofNode: false
                })
            )
        );
        address l2Token = makeAddr("l2Token");
        assetId = DataEncoding.encodeNTVAssetId(eraZKChainId, l2Token);
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: user,
            _remoteReceiver: user,
            _originToken: l2Token,
            _amount: _amount,
            _erc20Metadata: DataEncoding.encodeTokenData({
                _chainId: eraZKChainId,
                _name: abi.encode("L2 token"),
                _symbol: abi.encode("L2T"),
                _decimals: abi.encode(uint8(18))
            })
        });
        addresses.l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: eraZKChainId,
                l2BatchNumber: 1,
                l2MessageIndex: 1,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: 1,
                message: abi.encodePacked(
                    AssetRouterBase.finalizeDeposit.selector,
                    eraZKChainId,
                    assetId,
                    transferData
                ),
                merkleProof: new bytes32[](0)
            })
        );
        l1Token = IERC20(addresses.l1NativeTokenVault.tokenAddress(assetId));
    }

    function _depositL1Token(IERC20 _l1Token, bytes32 _assetId, uint256 _amount) internal {
        L2TransactionRequestTwoBridgesOuter memory request = _prepareL1TokenDeposit(_l1Token, _assetId, _amount);
        vm.prank(user);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);
    }

    function _setDepositCap(bytes32 _assetId, uint256 _cap) internal {
        bytes32[] memory assetIds = new bytes32[](1);
        assetIds[0] = _assetId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = _cap;
        vm.prank(chainAdmin);
        filterer.setDepositCaps(assetIds, caps);
    }

    /// @dev Caps the base token at `MINT_VALUE`, about the fee, and switches to `WITHDRAWALS_ONLY` mode.
    function _enterWithdrawalsOnlyMode() internal {
        _setDepositCap(baseTokenAssetId, MINT_VALUE);
        vm.prank(chainAdmin);
        filterer.setCallMode(CallMode.WITHDRAWALS_ONLY);
    }

    /// @dev Sends `user`'s L1 -> L2 call paying only `MINT_VALUE`: `_l2Value` comes from the sender's L2 balance.
    /// With `_fromEoa`, `user` is also `tx.origin`, as an EOA calling the Bridgehub directly.
    function _requestL2Call(address _l2Contract, uint256 _l2Value, bytes memory _l2Calldata, bool _fromEoa) internal {
        vm.deal(user, MINT_VALUE);
        vm.recordLogs();
        if (_fromEoa) {
            vm.prank(user, user);
        } else {
            vm.prank(user);
        }
        addresses.bridgehub.requestL2TransactionDirect{value: MINT_VALUE}(
            L2TransactionRequestDirect({
                chainId: eraZKChainId,
                mintValue: MINT_VALUE,
                l2Contract: _l2Contract,
                l2Value: _l2Value,
                l2Calldata: _l2Calldata,
                l2GasLimit: L2_GAS_LIMIT,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                refundRecipient: address(0)
            })
        );
    }

    function _priorityRequestTransaction() internal returns (L2CanonicalTransaction memory transaction) {
        (, , , transaction, ) = abi.decode(
            _priorityRequestLog().data,
            (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[])
        );
    }

    function _priorityRequestSelector() internal returns (bytes4) {
        return bytes4(_priorityRequestTransaction().data);
    }

    function test_tokenDepositWithinCapPasses() public {
        uint256 balanceBefore = token.balanceOf(address(addresses.l1NativeTokenVault));
        vm.recordLogs();
        assertNotEq(_depositToken(TOKEN_CAP), bytes32(0));
        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), balanceBefore + TOKEN_CAP);
        // The Era router sends L1-native tokens with the legacy encoding.
        assertEq(_priorityRequestSelector(), IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector);
    }

    /// @dev `L1ERC20Bridge.deposit` reaches the Mailbox from the L1 asset router, with the depositor as the
    /// legacy calldata's `l1Sender`.
    function test_l1Erc20BridgeDepositCapped() public {
        IL1ERC20Bridge legacyBridge = addresses.sharedBridge.legacyBridge();
        vm.deal(user, 2 * MINT_VALUE);
        token.mint(user, 2 * TOKEN_CAP + 1);
        vm.startPrank(user);
        token.approve(address(legacyBridge), 2 * TOKEN_CAP + 1);
        vm.recordLogs();
        legacyBridge.deposit{value: MINT_VALUE}(
            user,
            address(token),
            TOKEN_CAP,
            L2_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        assertEq(_priorityRequestSelector(), IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector);

        vm.expectRevert(TransactionNotAllowed.selector);
        legacyBridge.deposit{value: MINT_VALUE}(
            user,
            address(token),
            TOKEN_CAP + 1,
            L2_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        vm.stopPrank();
    }

    /// @dev A token native to the chain, withdrawn to L1 and deposited back, goes through the new encoding and is
    /// capped under the asset id of its L2 origin.
    function test_bridgedBackTokenDepositCapped() public {
        (IERC20 l1Token, bytes32 assetId) = _withdrawL2NativeToken(2 * TOKEN_CAP + 1);
        assertEq(l1Token.balanceOf(user), 2 * TOKEN_CAP + 1);

        L2TransactionRequestTwoBridgesOuter memory request = _prepareL1TokenDeposit(l1Token, assetId, 1);
        vm.prank(user);
        vm.expectRevert(TransactionNotAllowed.selector);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);

        _setDepositCap(assetId, TOKEN_CAP);
        vm.recordLogs();
        _depositL1Token(l1Token, assetId, TOKEN_CAP);
        assertEq(_priorityRequestSelector(), AssetRouterBase.finalizeDeposit.selector);
        assertEq(l1Token.balanceOf(user), TOKEN_CAP + 1);

        request = _prepareL1TokenDeposit(l1Token, assetId, TOKEN_CAP + 1);
        vm.prank(user);
        vm.expectRevert(TransactionNotAllowed.selector);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);
    }

    function test_tokenDepositAboveCapReverts() public {
        L2TransactionRequestTwoBridgesOuter memory request = _prepareTokenDeposit(TOKEN_CAP + 1);
        vm.prank(user);
        vm.expectRevert(TransactionNotAllowed.selector);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);
    }

    function test_exemptDepositorBypassesTokenCap() public {
        vm.prank(chainAdmin);
        filterer.setExempt(user, true);
        assertNotEq(_depositToken(TOKEN_CAP + 1), bytes32(0));
    }

    function test_tokenDepositRevertsInWithdrawalsOnlyMode() public {
        vm.prank(chainAdmin);
        filterer.setCallMode(CallMode.WITHDRAWALS_ONLY);
        L2TransactionRequestTwoBridgesOuter memory request = _prepareTokenDeposit(1);
        vm.prank(user);
        vm.expectRevert(TransactionNotAllowed.selector);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: MINT_VALUE}(request);
    }

    /// @dev The `sender` of a Bridgehub deposit is the L1 asset router, so the exemption is checked against the
    /// depositor decoded from the calldata, which keeps an exempt account depositing in `WITHDRAWALS_ONLY` mode.
    function test_exemptDepositorDepositsInWithdrawalsOnlyMode() public {
        _enterWithdrawalsOnlyMode();
        vm.prank(chainAdmin);
        filterer.setExempt(user, true);

        uint256 balanceBefore = token.balanceOf(address(addresses.l1NativeTokenVault));
        vm.recordLogs();
        assertNotEq(_depositToken(TOKEN_CAP + 1), bytes32(0));
        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), balanceBefore + TOKEN_CAP + 1);
        assertEq(_priorityRequestSelector(), IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector);
    }

    function test_baseTokenDepositCappedOnMintValue() public {
        assertNotEq(_depositBaseToken(1 ether), bytes32(0));

        bytes32[] memory assetIds = new bytes32[](1);
        assetIds[0] = baseTokenAssetId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = MINT_VALUE;
        vm.prank(chainAdmin);
        filterer.setDepositCaps(assetIds, caps);

        assertNotEq(_depositBaseToken(0), bytes32(0));
        vm.expectRevert(TransactionNotAllowed.selector);
        _depositBaseToken(1);
    }

    /// @dev A forced base token withdrawal from L1 still reaches the priority queue in `WITHDRAWALS_ONLY` mode,
    /// with the base token capped near the fee level, while a plain base token deposit is rejected.
    function test_forcedWithdrawalPassesInWithdrawalsOnlyMode() public {
        _enterWithdrawalsOnlyMode();

        bytes memory withdrawal = abi.encodeCall(IBaseToken.withdraw, (user));
        _requestL2Call(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, 0, withdrawal, false);
        L2CanonicalTransaction memory transaction = _priorityRequestTransaction();
        assertEq(address(uint160(transaction.to)), L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(keccak256(transaction.data), keccak256(withdrawal));
        assertEq(transaction.reserved[0], MINT_VALUE);

        vm.expectRevert(TransactionNotAllowed.selector);
        _depositBaseToken(0);
    }

    /// @dev ETH stuck on L2 is withdrawn by paying only the fee on L1: the cap applies to `mintValue`, and `l2Value`
    /// is not part of it. The bootloader mints `mintValue` minus the fee to the sender and takes `l2Value` from the
    /// sender's L2 balance (`processL1Tx` and `executeL1Tx` in `bootloader.yul`). An EOA's L1 -> L2 transaction
    /// comes from its own address, so that balance is the stuck one.
    function test_forcedWithdrawalOfStuckEthFromEoa() public {
        _enterWithdrawalsOnlyMode();

        bytes memory withdrawal = abi.encodeCall(IBaseToken.withdraw, (user));
        _requestL2Call(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, STUCK_ETH, withdrawal, true);
        L2CanonicalTransaction memory transaction = _priorityRequestTransaction();
        assertEq(address(uint160(transaction.from)), user);
        assertEq(address(uint160(transaction.to)), L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(transaction.value, STUCK_ETH);
        assertEq(transaction.reserved[0], MINT_VALUE);
        assertEq(keccak256(transaction.data), keccak256(withdrawal));
    }

    /// @dev A contract's L1 -> L2 transaction comes from its alias, so a forced withdrawal moves the alias's L2
    /// balance, not one at the contract's own address.
    function test_forcedWithdrawalFromContractComesFromAlias() public {
        _enterWithdrawalsOnlyMode();

        _requestL2Call(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            STUCK_ETH,
            abi.encodeCall(IBaseToken.withdraw, (user)),
            false
        );
        assertEq(address(uint160(_priorityRequestTransaction().from)), AddressAliasHelper.applyL1ToL2Alias(user));
    }

    /// @dev Both L2 asset router withdrawal functions pass in `WITHDRAWALS_ONLY` mode, for any amount: deposit caps
    /// don't apply to withdrawals. On L2 they burn a token bridged from L1 without an allowance
    /// (`L2ForcedWithdrawalTestAbstract`).
    function test_forcedTokenWithdrawalPassesInWithdrawalsOnlyMode() public {
        _enterWithdrawalsOnlyMode();
        address l2Token = makeAddr("l2Token");
        uint256 stuckAmount = TOKEN_CAP + 1;

        bytes[] memory withdrawals = new bytes[](2);
        withdrawals[0] = abi.encodeCall(
            IL2AssetRouter.withdraw,
            (tokenAssetId, DataEncoding.encodeBridgeBurnData(stuckAmount, user, l2Token))
        );
        withdrawals[1] = abi.encodeCall(IL2SharedBridgeLegacy.withdraw, (user, l2Token, stuckAmount));
        for (uint256 i = 0; i < withdrawals.length; ++i) {
            _requestL2Call(L2_ASSET_ROUTER_ADDR, 0, withdrawals[i], true);
            L2CanonicalTransaction memory transaction = _priorityRequestTransaction();
            assertEq(address(uint160(transaction.from)), user);
            assertEq(address(uint160(transaction.to)), L2_ASSET_ROUTER_ADDR);
            assertEq(keccak256(transaction.data), keccak256(withdrawals[i]));
        }
    }

    /// @dev A token native to L2 needs an `approve` of the L2 native token vault before its withdrawal
    /// (`L2ForcedWithdrawalTestAbstract`). `WITHDRAWALS_ONLY` mode rejects that call until the chain admin allows it.
    function test_l2NativeTokenApproveNeedsAllowingInWithdrawalsOnlyMode() public {
        _enterWithdrawalsOnlyMode();
        address l2NativeToken = makeAddr("l2NativeToken");
        bytes memory approval = abi.encodeCall(IERC20.approve, (L2_NATIVE_TOKEN_VAULT_ADDR, TOKEN_CAP));

        vm.expectRevert(TransactionNotAllowed.selector);
        _requestL2Call(l2NativeToken, 0, approval, true);

        vm.prank(chainAdmin);
        filterer.setWithdrawalFunction(l2NativeToken, IERC20.approve.selector, true);
        _requestL2Call(l2NativeToken, 0, approval, true);
        assertEq(keccak256(_priorityRequestTransaction().data), keccak256(approval));
    }

    function _priorityRequestLog() internal returns (Vm.Log memory) {
        return vm.getRecordedLogs().requireOne(NEW_PRIORITY_REQUEST_SIGNATURE);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
