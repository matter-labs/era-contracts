// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {TransactionNotAllowed} from "contracts/common/L1ContractErrors.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EraMaintenanceTransactionFilterer} from "contracts/transactionFilterer/EraMaintenanceTransactionFilterer.sol";
import {CallMode} from "contracts/transactionFilterer/interfaces/IEraMaintenanceTransactionFilterer.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

/// @dev Sends real Bridgehub deposits to a chain whose Mailbox uses the filterer, so the filterer decodes the
/// calldata the deployed L1 asset router builds rather than calldata assembled by the test.
contract EraMaintenanceTransactionFiltererIntegrationTest is
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer,
    L2TxMocker
{
    uint256 internal constant MINT_VALUE = 250000000000100;
    uint256 internal constant L2_GAS_LIMIT = 1000000;
    uint256 internal constant TOKEN_CAP = 1000;

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
        vm.deal(user, MINT_VALUE);
        token.mint(user, _amount);
        vm.prank(user);
        token.approve(address(addresses.l1NativeTokenVault), _amount);
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
                    abi.encode(tokenAssetId, abi.encode(_amount, user, address(token)))
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

    function test_tokenDepositWithinCapPasses() public {
        uint256 balanceBefore = token.balanceOf(address(addresses.l1NativeTokenVault));
        assertNotEq(_depositToken(TOKEN_CAP), bytes32(0));
        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), balanceBefore + TOKEN_CAP);
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

    // add this to be excluded from coverage report
    function test() internal override {}
}
