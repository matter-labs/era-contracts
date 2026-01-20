// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {SLNotWhitelisted} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {NotCurrentSettlementLayer, SettlementLayersMustSettleOnL1} from "contracts/common/L1ContractErrors.sol";

contract BridgehubNormalTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;

    function prepare() public {
        // _generateUserAddresses();

        _deployL1Contracts();
        // _deployTokens();
        // _registerNewTokens(tokens);

        // _deployEra();
        // _deployZKChain(ETH_TOKEN_ADDRESS);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            // l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    function test_removeChainTypeManager_addressZero() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address ctm = address(0);
        vm.expectRevert();
        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);
    }

    function test_removeChainTypeManager_addressOne() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address ctm = address(1);
        vm.expectRevert();
        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);
    }

    function test_removeChainTypeManager_correctCTM() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);

        // Optionally, check if the CTM for eraZKChainId is now zeroed out or expected state, e.g.:
        assertEq(addresses.bridgehub.chainTypeManager(eraZKChainId), address(0));
    }

    function test_setAddressesV31_onlyOwnerOrUpgrader_can_call() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address upgrader = makeAddr("upgrader"); // Assume this address is set as upgrader in the contract (mock appropriately)
        address newChainRegistrationSender = makeAddr("chainRegistrationSenderV31");

        // Call as owner - should succeed
        vm.prank(owner);
        addresses.bridgehub.setAddressesV31(newChainRegistrationSender);

        // You may want to verify effects if they are visible, e.g.:
        // assertEq(addresses.bridgehub.chainRegistrationSender(), newChainRegistrationSender);

        // Call as upgrader - should succeed if upgrader is set up in contract,
        // mock/assume if needed; otherwise, skip this part or mock the role as appropriate.
        // vm.prank(upgrader);
        // addresses.bridgehub.setAddressesV31(newChainRegistrationSender);

        // Non-owner, non-upgrader should revert
        address notAllowed = makeAddr("notAllowed");
        vm.expectRevert();
        vm.prank(notAllowed);
        addresses.bridgehub.setAddressesV31(newChainRegistrationSender);
    }

    function test_forwardedBridgeBurnSetSettlementLayer_revert_SLNotWhitelisted() public {
        // Setup: Use a fresh chainId that is not in the test setup to avoid conflicts
        uint256 chainId = 777777; // Fresh chain ID not used in setup
        uint256 nonWhitelistedSL = 888888;

        // Set settlementLayer[chainId] = block.chainid to pass that check
        stdstore.target(address(addresses.bridgehub)).sig("settlementLayer(uint256)").with_key(chainId).checked_write(
            block.chainid
        );

        vm.prank(addresses.bridgehub.chainAssetHandler());
        vm.expectRevert(abi.encodeWithSelector(SLNotWhitelisted.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, nonWhitelistedSL);
    }

    function test_forwardedBridgeBurnSetSettlementLayer_revert_NotCurrentSettlementLayer() public {
        // Setup: Use a fresh chainId that is not in the test setup to avoid conflicts
        uint256 chainId = 666666; // Fresh chain ID not used in setup
        uint256 validWhitelistedSL = block.chainid + 1;

        // Whitelist the validWhitelistedSL first
        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(validWhitelistedSL)
            .checked_write(block.chainid);
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(validWhitelistedSL, true);

        // Set settlementLayer[chainId] to not be block.chainid (to trigger NotCurrentSettlementLayer error)
        stdstore.target(address(addresses.bridgehub)).sig("settlementLayer(uint256)").with_key(chainId).checked_write(
            block.chainid + 8
        );

        vm.prank(addresses.bridgehub.chainAssetHandler());
        vm.expectRevert(abi.encodeWithSelector(NotCurrentSettlementLayer.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, validWhitelistedSL);
    }

    function test_forwardedBridgeBurnSetSettlementLayer_revert_SettlementLayersMustSettleOnL1() public {
        // Setup: Use a fresh chainId that we'll explicitly whitelist as a settlement layer
        uint256 chainId = 555555; // Fresh chain ID not used in setup
        uint256 validWhitelistedSL = block.chainid + 1;

        // Set settlementLayer for both chainId and validWhitelistedSL to block.chainid
        stdstore.target(address(addresses.bridgehub)).sig("settlementLayer(uint256)").with_key(chainId).checked_write(
            block.chainid
        );
        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(validWhitelistedSL)
            .checked_write(block.chainid);

        // Whitelist chainId as a settlement layer (this should cause the test to pass the first two checks but fail the third)
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(chainId, true);

        // Whitelist the new settlement layer destination so the first check passes
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(validWhitelistedSL, true);

        vm.prank(addresses.bridgehub.chainAssetHandler());
        vm.expectRevert(abi.encodeWithSelector(SettlementLayersMustSettleOnL1.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, validWhitelistedSL);
    }

    function test_getHyperchain_returnsZKChainAddress() public {
        // Test that getHyperchain is a legacy function that calls getZKChain
        // It should return the same value as getZKChain for any chainId

        uint256 testChainId = 12345;
        address hyperchainAddress = addresses.bridgehub.getHyperchain(testChainId);
        address zkChainAddress = addresses.bridgehub.getZKChain(testChainId);

        // Verify getHyperchain returns the same as getZKChain
        assertEq(hyperchainAddress, zkChainAddress, "getHyperchain should return the same address as getZKChain");
    }

    function test_getHyperchain_unregisteredChain() public {
        // Test that getHyperchain returns zero address for an unregistered chain
        uint256 unregisteredChainId = 999999;
        address zkChainAddress = addresses.bridgehub.getHyperchain(unregisteredChainId);

        assertEq(zkChainAddress, address(0), "Unregistered chain should return zero address");
    }

    function test_sharedBridge() public {
        // Test that sharedBridge returns the asset router address
        address sharedBridgeAddress = addresses.bridgehub.sharedBridge();

        // Verify it returns the asset router address
        assertEq(
            sharedBridgeAddress,
            address(addresses.bridgehub.assetRouter()),
            "sharedBridge should return asset router address"
        );

        // Verify it's not zero address
        assertTrue(sharedBridgeAddress != address(0), "Asset router should have non-zero address");
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
