// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BridgehubInvariantTests} from "./BridgehubTests.t.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

contract L1InteropRequestHelpersIntegrationTest is BridgehubInvariantTests {
    uint256 private requestChainId;
    uint256 private constant REQUEST_GAS_LIMIT = 1_000_000;

    function setUp() public {
        prepare();
        for (uint256 i = 0; i < zkChainIds.length; ++i) {
            if (getZKChainBaseToken(zkChainIds[i]) != ETH_TOKEN_ADDRESS) {
                requestChainId = zkChainIds[i];
                return;
            }
        }
        revert("ERC20-base chain missing from integration harness");
    }

    function test_preparedAdminAndGovernanceRequestsFundERC20BaseToken() public {
        bool[2] memory modes = [false, true];
        for (uint256 i = 0; i < modes.length; ++i) {
            for (uint256 j = 0; j < modes.length; ++j) {
                _executePreparedRequest(modes[i], modes[j]);
            }
        }
    }

    function _executePreparedRequest(bool _admin, bool _indirect) private {
        Call[] memory calls = _prepareRequest(_admin, _indirect);
        address caller = users[0];
        address vault = address(addresses.l1NativeTokenVault);
        TestnetERC20Token baseToken = TestnetERC20Token(getZKChainBaseToken(requestChainId));
        TestnetERC20Token depositToken = TestnetERC20Token(tokens[1]);
        uint256 mintValue = addresses.interopCenter.l2TransactionBaseCost(
            requestChainId,
            block.basefee + 1 gwei,
            REQUEST_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 10;
        uint256 baseBalanceBefore = baseToken.balanceOf(vault);
        uint256 depositBalanceBefore = depositToken.balanceOf(vault);
        if (_indirect) {
            depositToken.mint(caller, 1 ether);
            vm.prank(caller);
            depositToken.approve(vault, 1 ether);
        }
        baseToken.mint(caller, mintValue);
        bytes32 canonicalHash;
        {
            vm.recordLogs();
            vm.startPrank(caller, caller);
            bytes memory returnData;
            for (uint256 i = 0; i < calls.length; ++i) {
                bool success;
                (success, returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
                assertTrue(success, "Prepared request call failed");
            }
            vm.stopPrank();
            canonicalHash = abi.decode(returnData, (bytes32));
        }
        assertEq(canonicalHash, _getNewPriorityQueueFromLogs(vm.getRecordedLogs()).txHash);
        assertEq(baseToken.balanceOf(caller), 0);
        assertEq(baseToken.balanceOf(vault), baseBalanceBefore + mintValue);
        assertEq(baseToken.allowance(caller, vault), 0);
        assertEq(baseToken.allowance(caller, address(addresses.sharedBridge)), 0);
        if (_indirect) {
            assertEq(depositToken.balanceOf(caller), 0);
            assertEq(depositToken.balanceOf(vault), depositBalanceBefore + 1 ether);
            assertEq(
                addresses.l1Nullifier.depositHappened(requestChainId, canonicalHash),
                DataEncoding.encodeTxDataHash(
                    caller,
                    DataEncoding.encodeNTVAssetId(block.chainid, address(depositToken)),
                    DataEncoding.encodeBridgeBurnData(1 ether, caller, address(depositToken))
                )
            );
        }
    }

    function _prepareRequest(bool _admin, bool _indirect) private view returns (Call[] memory) {
        address caller = users[0];
        uint256 gasPrice = block.basefee + 1 gwei;
        if (_indirect) {
            bytes memory payload = DataEncoding.encodeAssetRouterDepositData(
                DataEncoding.encodeNTVAssetId(block.chainid, tokens[1]),
                DataEncoding.encodeBridgeBurnData(1 ether, caller, tokens[1])
            );
            return
                _admin
                    ? Utils.prepareAdminL1L2IndirectMessage(
                        gasPrice,
                        REQUEST_GAS_LIMIT,
                        requestChainId,
                        address(addresses.bridgehub),
                        address(addresses.sharedBridge),
                        0,
                        payload,
                        caller
                    )
                    : Utils.prepareGovernanceL1L2IndirectMessage(
                        gasPrice,
                        REQUEST_GAS_LIMIT,
                        requestChainId,
                        address(addresses.bridgehub),
                        address(addresses.sharedBridge),
                        0,
                        payload,
                        caller
                    );
        } else {
            return
                _admin
                    ? Utils.prepareAdminL1L2Message(
                        gasPrice,
                        hex"",
                        REQUEST_GAS_LIMIT,
                        new bytes[](0),
                        caller,
                        0,
                        requestChainId,
                        address(addresses.bridgehub),
                        caller
                    )
                    : Utils.prepareGovernanceL1L2Message(
                        gasPrice,
                        hex"",
                        REQUEST_GAS_LIMIT,
                        new bytes[](0),
                        caller,
                        requestChainId,
                        address(addresses.bridgehub),
                        caller
                    );
        }
    }
}
