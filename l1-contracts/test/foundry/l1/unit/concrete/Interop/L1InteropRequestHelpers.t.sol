// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract L1InteropRequestHelpersTest is Test {
    function testFuzz_indirectGovernanceAndAdminFunding(bool _ethBase, bool _admin, uint96 _forwardedValue) public {
        address bridgehub = makeAddr("bridgehub");
        address center = address(new L1InteropCenter(IL1Bridgehub(bridgehub)));
        address router = makeAddr("router");
        address vault = makeAddr("nativeTokenVault");
        // Isolate call construction from the on-chain registry and fee formula.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.interopCenter, ()), abi.encode(center));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(router));
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector),
            abi.encode(_ethBase ? ETH_TOKEN_ADDRESS : makeAddr("baseToken"))
        );
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.l2TransactionBaseCost.selector), abi.encode(123));
        vm.mockCall(router, abi.encodeCall(IL1AssetRouter.nativeTokenVault, ()), abi.encode(vault));
        Call[] memory calls = _admin
            ? Utils.prepareAdminL1L2IndirectMessage(
                1,
                1_000_000,
                271,
                bridgehub,
                router,
                _forwardedValue,
                hex"abcd",
                address(this)
            )
            : Utils.prepareGovernanceL1L2IndirectMessage(
                1,
                1_000_000,
                271,
                bridgehub,
                router,
                _forwardedValue,
                hex"abcd",
                address(this)
            );
        assertEq(calls.length, _ethBase ? 1 : 2);
        Call memory send = calls[calls.length - 1];
        assertEq(send.target, center);
        assertEq(send.value, (_ethBase ? 1230 : 0) + uint256(_forwardedValue));
        assertEq(bytes4(send.data), IERC7786GatewaySource.sendMessage.selector);
        (, bytes memory payload, bytes[] memory attrs) = this.decode(send.data);
        assertEq(payload, hex"abcd");
        assertEq(L1InteropCenter(center).parseL1Attributes(attrs).indirectCallMessageValue, _forwardedValue);
        assertEq(L1InteropCenter(center).parseL1Attributes(attrs).mintValue, 1230);
        if (!_ethBase) {
            assertEq(calls[0].target, makeAddr("baseToken"));
            assertEq(calls[0].value, 0);
            assertEq(calls[0].data, abi.encodeCall(IERC20.approve, (vault, 1230)));
        }
    }
    function decode(bytes calldata _data) external pure returns (bytes memory, bytes memory, bytes[] memory) {
        return abi.decode(_data[4:], (bytes, bytes, bytes[]));
    }
}
