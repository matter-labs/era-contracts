// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1WethBridgeTest} from "./_L1WethBridge_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "../../../../../../cache/solpp-generated-contracts/zksync/Config.sol";

contract DepositTest is L1WethBridgeTest {
    function test_RevertWhen_UnWhitelistedAddressDeposits() public {
        vm.prank(owner);
        allowList.setAccessMode(address(bridgeProxy), IAllowList.AccessMode.Closed);

        vm.prank(randomSigner);
        vm.expectRevert(bytes.concat("nr"));
        bridgeProxy.deposit(randomSigner, address(0), 0, 0, 0, address(0));
    }

    function test_RevertWhen_ReceivedL1TokenIsNotL1WethAddress() public {
        vm.expectRevert("Invalid L1 token address");
        bridgeProxy.deposit(randomSigner, makeAddr("invalidL1TokenAddress"), 0, 0, 0, address(0));
    }

    function test_RevertWhen_DepositingZeroWETH() public {
        bytes memory depositCallData = abi.encodeWithSelector(
            bridgeProxy.deposit.selector,
            randomSigner,
            bridgeProxy.l1WethAddress(),
            0,
            0,
            0,
            address(0)
        );

        vm.expectRevert("Amount cannot be zero");
        // solhint-disable-next-line avoid-low-level-calls
        (bool revertAsExpected, ) = address(bridgeProxy).call(depositCallData);
        assertTrue(revertAsExpected, "expectRevert: call did not revert");
    }

    function test_DepositSuccessfully() public {
        uint256 amount = 100;

        hoax(randomSigner);
        l1Weth.deposit{value: amount}();

        hoax(randomSigner);
        l1Weth.approve(address(bridgeProxy), amount);

        bytes memory depositCallData = abi.encodeWithSelector(
            bridgeProxy.deposit.selector,
            randomSigner,
            bridgeProxy.l1WethAddress(),
            amount,
            1000000,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            randomSigner
        );

        hoax(randomSigner);
        (bool success, ) = address(bridgeProxy).call{value: 1000000000000000000}(depositCallData);
        assertTrue(success, "call did not succeed");
    }

    function test_DepositSuccessfullyIfRefundRecipientIsNotSpecified() public {
        uint256 amount = 100;

        hoax(randomSigner);
        l1Weth.deposit{value: amount}();

        hoax(randomSigner);
        l1Weth.approve(address(bridgeProxy), amount);

        bytes memory depositCallData = abi.encodeWithSelector(
            bridgeProxy.deposit.selector,
            randomSigner,
            bridgeProxy.l1WethAddress(),
            amount,
            1000000,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            address(0)
        );

        hoax(randomSigner);
        (bool success, ) = address(bridgeProxy).call{value: 1000000000000000000}(depositCallData);
        assertTrue(success, "call did not succeed");
    }
}
