// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_CREATE2_FACTORY_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {CallMode} from "contracts/transactionFilterer/interfaces/IEraMaintenanceTransactionFilterer.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";

import {EraMaintenanceTransactionFiltererTest} from "./_EraMaintenanceTransactionFilterer_Shared.t.sol";

contract CheckTransactionTest is EraMaintenanceTransactionFiltererTest {
    address internal l2Contract = makeAddr("l2Contract");
    address internal lidoL2Bridge = makeAddr("lidoL2Bridge");

    function setUp() public override {
        super.setUp();
        _setCap(tokenAssetId, TOKEN_CAP);
    }

    function _allowed(
        address _sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes memory _l2Calldata
    ) internal view returns (bool) {
        return
            _allowedWithRefund({
                _sender: _sender,
                _contractL2: _contractL2,
                _mintValue: _mintValue,
                _l2Value: _l2Value,
                _l2Calldata: _l2Calldata,
                _refundRecipient: user
            });
    }

    function _allowedWithRefund(
        address _sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes memory _l2Calldata,
        address _refundRecipient
    ) internal view returns (bool) {
        return
            filterer.isTransactionAllowed({
                _sender: _sender,
                _contractL2: _contractL2,
                _mintValue: _mintValue,
                _l2Value: _l2Value,
                _l2Calldata: _l2Calldata,
                _refundRecipient: _refundRecipient
            });
    }

    function _txHash(
        address _sender,
        address _contractL2,
        uint256 _l2Value,
        bytes memory _l2Calldata,
        address _refundRecipient
    ) internal view returns (bytes32) {
        return
            filterer.getTxHash({
                _sender: _sender,
                _contractL2: _contractL2,
                _l2Value: _l2Value,
                _l2Calldata: _l2Calldata,
                _refundRecipient: _refundRecipient
            });
    }

    function _setCallMode(CallMode _callMode) internal {
        vm.prank(owner);
        filterer.setCallMode(_callMode);
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_newEncodingDepositWithinCap() public view {
        bytes memory data = _newDepositCalldata(user, tokenAssetId, TOKEN_CAP);
        assertTrue(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_newEncodingDepositAboveCap() public view {
        bytes memory data = _newDepositCalldata(user, tokenAssetId, TOKEN_CAP + 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_newEncodingDepositOfNotWhitelistedToken() public view {
        bytes memory data = _newDepositCalldata(user, keccak256("otherAsset"), 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_legacyEncodingDepositWithinCap() public view {
        bytes memory data = _legacyDepositCalldata(user, l1Token, TOKEN_CAP);
        assertTrue(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_legacyEncodingDepositAboveCap() public view {
        bytes memory data = _legacyDepositCalldata(user, l1Token, TOKEN_CAP + 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_legacyEncodingDepositOfNotWhitelistedToken() public {
        bytes memory data = _legacyDepositCalldata(user, makeAddr("otherToken"), 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_depositRejectedWhenTokenCapRemoved() public {
        _setCap(tokenAssetId, 0);
        assertFalse(
            _allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, _newDepositCalldata(user, tokenAssetId, 1))
        );
        assertFalse(
            _allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, _legacyDepositCalldata(user, l1Token, 1))
        );
    }

    function test_depositRejectedWhenMintValueAboveBaseTokenCap() public {
        _setCap(baseTokenAssetId, MINT_VALUE - 1);
        bytes memory data = _newDepositCalldata(user, tokenAssetId, 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
        assertTrue(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE - 1, 0, data));
    }

    function test_depositRejectedInWithdrawalsOnlyMode() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertFalse(
            _allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, _newDepositCalldata(user, tokenAssetId, 1))
        );
        assertFalse(
            _allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, _legacyDepositCalldata(user, l1Token, 1))
        );
    }

    /// @dev The exemption of a deposit is checked against the depositor decoded from the calldata, since the
    /// `sender` of every Bridgehub deposit is the L1 asset router.
    function test_exemptDepositorBypassesCaps() public {
        vm.prank(owner);
        filterer.setExempt(user, true);
        _setCap(baseTokenAssetId, 1);

        bytes32 otherAsset = keccak256("otherAsset");
        assertTrue(
            _allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, _newDepositCalldata(user, otherAsset, 1e30))
        );
        assertTrue(
            _allowed(
                l1AssetRouter,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                _legacyDepositCalldata(user, makeAddr("otherToken"), 1e30)
            )
        );
        // A different depositor is still restricted.
        assertFalse(
            _allowed(
                l1AssetRouter,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                _newDepositCalldata(makeAddr("other"), tokenAssetId, 1)
            )
        );
    }

    /// @dev An exempt depositor keeps depositing in `WITHDRAWALS_ONLY` mode, through the asset router in both
    /// encodings and through a legacy bridge, while the deposits of other depositors are rejected.
    function test_exemptDepositorPassesInWithdrawalsOnlyMode() public {
        vm.startPrank(owner);
        filterer.setExempt(user, true);
        filterer.setLegacyBridge(lidoL1Bridge, true);
        vm.stopPrank();
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        _setCap(baseTokenAssetId, 1);
        _setCap(lidoAssetId, TOKEN_CAP);

        assertTrue(
            _allowed(
                l1AssetRouter,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                _newDepositCalldata(user, tokenAssetId, TOKEN_CAP + 1)
            )
        );
        assertTrue(
            _allowed(
                l1AssetRouter,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                _legacyDepositCalldata(user, l1Token, TOKEN_CAP + 1)
            )
        );
        assertTrue(_allowed(lidoL1Bridge, lidoL2Bridge, MINT_VALUE, 0, _legacyDepositCalldata(user, lidoL1Token, 1)));

        address other = makeAddr("other");
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, 1, 0, _newDepositCalldata(other, tokenAssetId, 1)));
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, 1, 0, _legacyDepositCalldata(other, l1Token, 1)));
        assertFalse(_allowed(lidoL1Bridge, lidoL2Bridge, 1, 0, _legacyDepositCalldata(other, lidoL1Token, 1)));
    }

    /// @dev In `WITHDRAWALS_ONLY` mode a message of the L1 asset router is still checked as a deposit, so it does
    /// not pass as a withdrawal call even if its selector is registered.
    function test_assetRouterMessageNotAWithdrawalCallInWithdrawalsOnlyMode() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        bytes memory withdrawal = abi.encodeCall(IL2AssetRouter.withdraw, (tokenAssetId, hex""));
        assertTrue(_allowed(user, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, withdrawal));
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, withdrawal));
    }

    function test_assetRouterMessageToOtherL2ContractRejected() public view {
        bytes memory data = _newDepositCalldata(user, tokenAssetId, 1);
        assertFalse(_allowed(l1AssetRouter, l2Contract, MINT_VALUE, 0, data));
    }

    function test_assetRouterMessageWithL2ValueRejected() public view {
        bytes memory data = _newDepositCalldata(user, tokenAssetId, 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 1, data));
    }

    function test_assetRouterMessageWithUnknownSelectorRejected() public view {
        bytes memory data = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (block.chainid, tokenAssetId, l2Contract)
        );
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, hex"aabbcc"));
    }

    /// @dev The transfer data of a non-NTV asset is handler-defined, so neither its depositor nor its amount can
    /// be trusted: such deposits are rejected even when the asset has a cap and the decoded depositor is exempt.
    function test_depositOfNonNtvAssetRejected() public {
        bytes32 customAssetId = keccak256("customAsset");
        vm.mockCall(
            l1AssetRouter,
            abi.encodeCall(IAssetRouterBase.assetHandlerAddress, (customAssetId)),
            abi.encode(makeAddr("customHandler"))
        );
        _setCap(customAssetId, type(uint256).max);
        vm.prank(owner);
        filterer.setExempt(user, true);

        bytes memory data = _newDepositCalldata(user, customAssetId, 1);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    /// @dev Malformed deposit calldata reverts the request instead of passing it.
    function test_revertWhen_depositTransferDataUndecodable() public {
        bytes memory data = abi.encodeCall(AssetRouterBase.finalizeDeposit, (block.chainid, tokenAssetId, hex"01"));
        vm.expectRevert();
        filterer.isTransactionAllowed({
            _sender: l1AssetRouter,
            _contractL2: L2_ASSET_ROUTER_ADDR,
            _mintValue: MINT_VALUE,
            _l2Value: 0,
            _l2Calldata: data,
            _refundRecipient: user
        });
    }

    /*//////////////////////////////////////////////////////////////
                        LEGACY (CUSTOM) BRIDGES
    //////////////////////////////////////////////////////////////*/

    function test_legacyBridgeDepositIsCapped() public {
        vm.prank(owner);
        filterer.setLegacyBridge(lidoL1Bridge, true);
        bytes memory data = _legacyDepositCalldata(user, lidoL1Token, 1);

        // Not whitelisted: rejected even in ALLOW_ALL mode.
        assertFalse(_allowed(lidoL1Bridge, lidoL2Bridge, MINT_VALUE, 0, data));

        _setCap(lidoAssetId, TOKEN_CAP);
        assertTrue(_allowed(lidoL1Bridge, lidoL2Bridge, MINT_VALUE, 0, data));
        assertFalse(
            _allowed(
                lidoL1Bridge,
                lidoL2Bridge,
                MINT_VALUE,
                0,
                _legacyDepositCalldata(user, lidoL1Token, TOKEN_CAP + 1)
            )
        );
    }

    function test_unregisteredLegacyBridgeIsAGenericCall() public view {
        bytes memory data = _legacyDepositCalldata(user, lidoL1Token, 1e30);
        assertTrue(_allowed(lidoL1Bridge, lidoL2Bridge, MINT_VALUE, 0, data));
    }

    function test_legacyBridgeNonDepositCallIsAGenericCall() public {
        vm.prank(owner);
        filterer.setLegacyBridge(lidoL1Bridge, true);
        bytes memory data = abi.encodeCall(IL2SharedBridgeLegacy.withdraw, (user, lidoL1Token, 1));
        assertTrue(_allowed(lidoL1Bridge, lidoL2Bridge, MINT_VALUE, 0, data));
    }

    function test_legacyBridgeWithdrawalInWithdrawalsOnlyMode() public {
        bytes memory withdrawal = abi.encodeCall(IL2SharedBridgeLegacy.withdraw, (user, lidoL1Token, 1));
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertFalse(_allowed(user, lidoL2Bridge, MINT_VALUE, 0, withdrawal));

        vm.prank(owner);
        filterer.setWithdrawalFunction(lidoL2Bridge, IL2SharedBridgeLegacy.withdraw.selector, true);
        assertTrue(_allowed(user, lidoL2Bridge, MINT_VALUE, 0, withdrawal));
    }

    /*//////////////////////////////////////////////////////////////
                        GENERIC CALLS
    //////////////////////////////////////////////////////////////*/

    function test_genericCallAllowedInAllowAllMode() public view {
        assertTrue(_allowed(user, l2Contract, MINT_VALUE, 1, hex"12345678"));
        assertTrue(_allowed(user, user, MINT_VALUE, MINT_VALUE, hex""));
    }

    function test_genericCallRejectedAboveBaseTokenCap() public {
        _setCap(baseTokenAssetId, MINT_VALUE);
        assertTrue(_allowed(user, l2Contract, MINT_VALUE, 0, hex""));
        assertFalse(_allowed(user, l2Contract, MINT_VALUE + 1, 0, hex""));
    }

    function test_allCallsRejectedWhenBaseTokenCapIsZero() public {
        _setCap(baseTokenAssetId, 0);
        assertFalse(_allowed(user, l2Contract, 0, 0, hex""));
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, 0, 0, _newDepositCalldata(user, tokenAssetId, 1)));
    }

    /// @dev `Create2Factory.create2` has the same signature as `ContractDeployer.create2`.
    function test_deployerTargetsRejectedInEitherMode() public {
        bytes memory data = abi.encodeCall(IL2ContractDeployer.create2, (bytes32(0), bytes32(0), hex""));
        assertFalse(_allowed(user, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, data));
        assertFalse(_allowed(user, L2_CREATE2_FACTORY_ADDR, MINT_VALUE, 0, data));
        // Any calldata, not only a deployment.
        assertFalse(_allowed(user, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, MINT_VALUE, MINT_VALUE, hex""));

        // Registering a deployer function for `WITHDRAWALS_ONLY` mode does not let it through either.
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        vm.prank(owner);
        filterer.setWithdrawalFunction(L2_CREATE2_FACTORY_ADDR, IL2ContractDeployer.create2.selector, true);
        assertFalse(_allowed(user, L2_CREATE2_FACTORY_ADDR, MINT_VALUE, 0, data));
    }

    function test_deployerTargetsPassForExemptSenderAndAllowedTxHash() public {
        bytes memory data = abi.encodeCall(IL2ContractDeployer.create2, (bytes32(0), bytes32(0), hex""));
        address governance = makeAddr("governance");
        vm.startPrank(owner);
        filterer.setExempt(governance, true);
        filterer.setAllowedTxHash(_txHash(user, L2_CREATE2_FACTORY_ADDR, 0, data, user), true);
        vm.stopPrank();

        assertTrue(_allowed(governance, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, data));
        assertTrue(_allowed(user, L2_CREATE2_FACTORY_ADDR, MINT_VALUE, 0, data));
        assertFalse(_allowed(user, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, data));
    }

    function test_withdrawalsOnlyModeAllowsDefaultWithdrawalFunctions() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertTrue(
            _allowed(
                user,
                L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
                MINT_VALUE,
                MINT_VALUE,
                abi.encodeCall(IBaseToken.withdraw, (user))
            )
        );
        assertTrue(
            _allowed(
                user,
                L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
                MINT_VALUE,
                MINT_VALUE,
                abi.encodeCall(IBaseToken.withdrawWithMessage, (user, hex"01"))
            )
        );
        assertTrue(
            _allowed(
                user,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                abi.encodeCall(IL2AssetRouter.withdraw, (tokenAssetId, hex""))
            )
        );
        assertTrue(
            _allowed(
                user,
                L2_ASSET_ROUTER_ADDR,
                MINT_VALUE,
                0,
                abi.encodeCall(IL2SharedBridgeLegacy.withdraw, (user, l2Contract, 1))
            )
        );
    }

    function test_withdrawalsOnlyModeRejectsOtherCalls() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        // Plain base token transfer.
        assertFalse(_allowed(user, user, MINT_VALUE, MINT_VALUE, hex""));
        // Calldata shorter than a selector.
        assertFalse(_allowed(user, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, hex"aabb"));
        // A withdrawal selector on a contract it is not registered for.
        assertFalse(_allowed(user, l2Contract, MINT_VALUE, 0, abi.encodeCall(IBaseToken.withdraw, (user))));
        // An unregistered function of a registered contract.
        assertFalse(_allowed(user, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, hex"12345678"));
    }

    function test_withdrawalRejectedAboveBaseTokenCap() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        _setCap(baseTokenAssetId, MINT_VALUE - 1);
        bytes memory data = abi.encodeCall(IBaseToken.withdraw, (user));
        assertFalse(_allowed(user, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, data));
    }

    function test_withdrawalFunctionRemoved() public {
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        vm.prank(owner);
        filterer.setWithdrawalFunction(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, IBaseToken.withdraw.selector, false);
        bytes memory data = abi.encodeCall(IBaseToken.withdraw, (user));
        assertFalse(_allowed(user, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, MINT_VALUE, 0, data));
    }

    function test_exemptSenderBypassesAllRestrictions() public {
        address hubPool = makeAddr("hubPool");
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        _setCap(baseTokenAssetId, 0);
        assertFalse(_allowed(hubPool, l2Contract, MINT_VALUE, 0, hex"12345678"));

        vm.prank(owner);
        filterer.setExempt(hubPool, true);
        assertTrue(_allowed(hubPool, l2Contract, MINT_VALUE, 0, hex"12345678"));
    }

    /*//////////////////////////////////////////////////////////////
                        POINTED WHITELISTED HASHES
    //////////////////////////////////////////////////////////////*/

    function test_allowedTxHashBypassesAllRestrictions() public {
        bytes memory data = hex"12345678";
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        _setCap(baseTokenAssetId, 0);
        assertFalse(_allowed(user, l2Contract, MINT_VALUE, 1, data));

        bytes32 txHash = _txHash(user, l2Contract, 1, data, user);
        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, true);

        // Any mintValue passes, and the entry is not consumed.
        assertTrue(_allowed(user, l2Contract, MINT_VALUE, 1, data));
        assertTrue(_allowed(user, l2Contract, 0, 1, data));

        // Changing any hashed parameter breaks the match.
        assertFalse(_allowed(l2Contract, l2Contract, MINT_VALUE, 1, data));
        assertFalse(_allowed(user, user, MINT_VALUE, 1, data));
        assertFalse(_allowed(user, l2Contract, MINT_VALUE, 2, data));
        assertFalse(_allowed(user, l2Contract, MINT_VALUE, 1, hex"12345679"));
        assertFalse(
            _allowedWithRefund({
                _sender: user,
                _contractL2: l2Contract,
                _mintValue: MINT_VALUE,
                _l2Value: 1,
                _l2Calldata: data,
                _refundRecipient: l2Contract
            })
        );

        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, false);
        assertFalse(_allowed(user, l2Contract, MINT_VALUE, 1, data));
    }

    /// @dev A whitelisted hash also lifts a deposit that the deposit rules reject.
    function test_allowedTxHashPassesRejectedDeposit() public {
        bytes memory data = _newDepositCalldata(user, tokenAssetId, TOKEN_CAP + 1);
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertFalse(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));

        bytes32 txHash = _txHash(l1AssetRouter, L2_ASSET_ROUTER_ADDR, 0, data, user);
        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, true);
        assertTrue(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    /// @dev The hash is checked before the deposit is decoded, so a whitelisted deposit passes even when its
    /// transfer data cannot be decoded.
    function test_allowedTxHashPassesUndecodableDeposit() public {
        bytes memory data = abi.encodeCall(AssetRouterBase.finalizeDeposit, (block.chainid, tokenAssetId, hex"01"));
        bytes32 txHash = _txHash(l1AssetRouter, L2_ASSET_ROUTER_ADDR, 0, data, user);
        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, true);
        assertTrue(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, data));
    }

    function test_getTxHashMatchesSpecifiedEncoding() public view {
        bytes memory data = hex"deadbeef";
        bytes32 expected = keccak256(abi.encode(user, l2Contract, uint256(7), keccak256(data), owner));
        assertEq(_txHash(user, l2Contract, 7, data, owner), expected);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_depositAllowedIffWithinBothCaps(
        uint256 _tokenCap,
        uint256 _amount,
        uint256 _baseTokenCap,
        uint256 _mintValue,
        bool _legacyEncoding
    ) public {
        _setCap(tokenAssetId, _tokenCap);
        _setCap(baseTokenAssetId, _baseTokenCap);
        bytes memory data = _legacyEncoding
            ? _legacyDepositCalldata(user, l1Token, _amount)
            : _newDepositCalldata(user, tokenAssetId, _amount);

        bool expected = _tokenCap != 0 && _amount <= _tokenCap && _baseTokenCap != 0 && _mintValue <= _baseTokenCap;
        assertEq(_allowed(l1AssetRouter, L2_ASSET_ROUTER_ADDR, _mintValue, 0, data), expected);
    }

    function testFuzz_withdrawalsOnlyRejectsUnregisteredSelectors(bytes4 _selector) public {
        vm.assume(_selector != IL2AssetRouter.withdraw.selector);
        vm.assume(_selector != IL2SharedBridgeLegacy.withdraw.selector);
        _setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertFalse(_allowed(user, L2_ASSET_ROUTER_ADDR, MINT_VALUE, 0, abi.encodePacked(_selector)));
    }
}
