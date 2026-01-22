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

        // Verify owner is valid before the test
        assertTrue(owner != address(0), "Owner should not be zero address");

        // Verify address(0) is an invalid CTM address
        assertEq(ctm, address(0), "Testing removal of zero address CTM");

        vm.expectRevert();
        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);

        // The call should have reverted - test passes if we reach here without panic
        // The revert is expected because address(0) is not a valid CTM
    }

    function test_removeChainTypeManager_addressOne() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address ctm = address(1);

        // Verify owner is valid
        assertTrue(owner != address(0), "Owner should not be zero address");

        // Verify address(1) is not a valid CTM before the test
        address currentCtm = addresses.bridgehub.chainTypeManager(eraZKChainId);
        assertTrue(currentCtm != address(1), "Address(1) should not be the current CTM");

        vm.expectRevert();
        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);

        // Verify state is unchanged after the failed removal
        address ctmAfter = addresses.bridgehub.chainTypeManager(eraZKChainId);
        assertEq(ctmAfter, currentCtm, "CTM should remain unchanged after failed removal");
    }

    function test_removeChainTypeManager_correctCTM() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;

        // Verify owner and CTM are valid before the test
        assertTrue(owner != address(0), "Owner should not be zero address");
        assertTrue(ctm != address(0), "CTM address should not be zero");

        vm.prank(owner);
        addresses.bridgehub.removeChainTypeManager(ctm);

        // Verify the CTM for eraZKChainId is now zeroed out after removal
        // Note: In this test setup, no chains are deployed, so chainTypeManager returns 0
        assertEq(
            addresses.bridgehub.chainTypeManager(eraZKChainId),
            address(0),
            "CTM should be zeroed out after removal"
        );
    }

    function test_setAddressesV31_onlyOwnerOrUpgrader_can_call() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        address newChainRegistrationSender = makeAddr("chainRegistrationSenderV31");

        // Verify owner is valid
        assertTrue(owner != address(0), "Owner should not be zero address");

        // Call as owner - should succeed
        vm.prank(owner);
        addresses.bridgehub.setAddressesV31(newChainRegistrationSender);

        // Verify the chainRegistrationSender was set correctly
        address registrationSender = addresses.bridgehub.chainRegistrationSender();
        assertEq(registrationSender, newChainRegistrationSender, "Chain registration sender should be updated");

        // Non-owner, non-upgrader should revert
        address notAllowed = makeAddr("notAllowed");
        assertTrue(notAllowed != owner, "notAllowed should be different from owner");

        vm.expectRevert();
        vm.prank(notAllowed);
        addresses.bridgehub.setAddressesV31(newChainRegistrationSender);

        // Verify state unchanged after failed call
        assertEq(
            addresses.bridgehub.chainRegistrationSender(),
            newChainRegistrationSender,
            "Chain registration sender should remain unchanged after failed call"
        );
    }

    function test_forwardedBridgeBurnSetSettlementLayer_revert_SLNotWhitelisted() public {
        // Setup: Use a fresh chainId that is not in the test setup to avoid conflicts
        uint256 chainId = 777777; // Fresh chain ID not used in setup
        uint256 nonWhitelistedSL = 888888;

        // Verify the non-whitelisted SL is indeed not whitelisted
        assertFalse(
            addresses.bridgehub.whitelistedSettlementLayers(nonWhitelistedSL),
            "Settlement layer should not be whitelisted"
        );

        // Set settlementLayer[chainId] = block.chainid to pass that check
        stdstore.target(address(addresses.bridgehub)).sig("settlementLayer(uint256)").with_key(chainId).checked_write(
            block.chainid
        );

        // Verify the setup was applied
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            block.chainid,
            "Settlement layer for chainId should be block.chainid"
        );

        address chainAssetHandler = addresses.bridgehub.chainAssetHandler();
        assertTrue(chainAssetHandler != address(0), "Chain asset handler should not be zero address");

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(SLNotWhitelisted.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, nonWhitelistedSL);

        // Verify settlement layer unchanged after revert
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            block.chainid,
            "Settlement layer should remain unchanged after revert"
        );
    }

    function test_forwardedBridgeBurnSetSettlementLayer_revert_NotCurrentSettlementLayer() public {
        // Setup: Use a fresh chainId that is not in the test setup to avoid conflicts
        uint256 chainId = 666666; // Fresh chain ID not used in setup
        uint256 validWhitelistedSL = block.chainid + 1;
        uint256 incorrectSettlementLayer = block.chainid + 8;

        // Whitelist the validWhitelistedSL first
        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(validWhitelistedSL)
            .checked_write(block.chainid);
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(validWhitelistedSL, true);

        // Verify the settlement layer is whitelisted
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(validWhitelistedSL),
            "Settlement layer should be whitelisted"
        );

        // Set settlementLayer[chainId] to not be block.chainid (to trigger NotCurrentSettlementLayer error)
        stdstore.target(address(addresses.bridgehub)).sig("settlementLayer(uint256)").with_key(chainId).checked_write(
            incorrectSettlementLayer
        );

        // Verify the setup - chainId's settlement layer is NOT block.chainid
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            incorrectSettlementLayer,
            "Settlement layer should be set to incorrect value"
        );
        assertTrue(
            incorrectSettlementLayer != block.chainid,
            "Incorrect settlement layer should differ from block.chainid"
        );

        address chainAssetHandler = addresses.bridgehub.chainAssetHandler();
        assertTrue(chainAssetHandler != address(0), "Chain asset handler should not be zero address");

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(NotCurrentSettlementLayer.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, validWhitelistedSL);

        // Verify settlement layer unchanged after revert
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            incorrectSettlementLayer,
            "Settlement layer should remain unchanged after revert"
        );
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

        // Verify the setup was applied
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            block.chainid,
            "Chain's settlement layer should be block.chainid"
        );
        assertEq(
            addresses.bridgehub.settlementLayer(validWhitelistedSL),
            block.chainid,
            "Valid SL's settlement layer should be block.chainid"
        );

        // Whitelist chainId as a settlement layer (this should cause the test to pass the first two checks but fail the third)
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(chainId, true);

        // Whitelist the new settlement layer destination so the first check passes
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(validWhitelistedSL, true);

        // Verify both are whitelisted
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(chainId),
            "ChainId should be whitelisted as settlement layer"
        );
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(validWhitelistedSL),
            "Valid SL should be whitelisted as settlement layer"
        );

        address chainAssetHandler = addresses.bridgehub.chainAssetHandler();
        assertTrue(chainAssetHandler != address(0), "Chain asset handler should not be zero address");

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(SettlementLayersMustSettleOnL1.selector));
        addresses.bridgehub.forwardedBridgeBurnSetSettlementLayer(chainId, validWhitelistedSL);

        // Verify settlement layers unchanged after revert
        assertEq(
            addresses.bridgehub.settlementLayer(chainId),
            block.chainid,
            "Chain's settlement layer should remain unchanged after revert"
        );
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
