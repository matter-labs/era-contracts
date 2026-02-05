// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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

contract DeploymentTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        if (users.length != 0) {
            revert AddressesAlreadyGenerated();
        }

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    // Check whether the sum of ETH deposits from tests, updated on each deposit and withdrawal,
    // equals the balance of L1Shared bridge.
    function test_initialDeployment() public {
        uint256 chainId = zkChainIds[0];
        address newChainAddress = addresses.bridgehub.getZKChain(chainId);
        address admin = IZKChain(addresses.bridgehub.getZKChain(chainId)).getAdmin();

        assertNotEq(admin, address(0));
        assertNotEq(newChainAddress, address(0));

        address[] memory chainAddresses = addresses.bridgehub.getAllZKChains();
        assertEq(chainAddresses.length, 2);
        assertEq(chainAddresses[0], newChainAddress);

        uint256[] memory chainIds = addresses.bridgehub.getAllZKChainChainIDs();
        assertEq(chainIds.length, 2);
        assertEq(chainIds[0], chainId);

        uint256 protocolVersion = addresses.chainTypeManager.getProtocolVersion(chainId);
        assertEq(protocolVersion, 133143986176);
    }

    function test_registerAlreadyDeployedZKChain() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);

            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                owner,
                addresses.chainTypeManager.protocolVersion(),
                addresses.chainTypeManager.storedBatchZero(),
                address(addresses.bridgehub),
                address(addresses.interopCenter)
            );

            address stmAddr = IZKChain(chain).getChainTypeManager();

            vm.startBroadcast(owner);
            addresses.bridgehub.addChainTypeManager(stmAddr);
            addresses.bridgehub.addTokenAssetId(baseTokenAssetId);
            addresses.bridgehub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();

            address bridgehubStmForChain = addresses.bridgehub.chainTypeManager(chainId);
            bytes32 bridgehubBaseAssetIdForChain = addresses.bridgehub.baseTokenAssetId(chainId);
            address bridgehubChainAddressForChain = addresses.bridgehub.getZKChain(chainId);
            address bhAddr = IZKChain(chain).getBridgehub();

            assertEq(bridgehubStmForChain, stmAddr);
            assertEq(bridgehubBaseAssetIdForChain, baseTokenAssetId);
            assertEq(bridgehubChainAddressForChain, chain);
            assertEq(bhAddr, address(addresses.bridgehub));
        }

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);

            // Verify chain is not registered before
            assertEq(
                addresses.bridgehub.getZKChain(chainId),
                address(0),
                "Chain should not be registered before deployment"
            );

            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                owner,
                addresses.chainTypeManager.protocolVersion(),
                addresses.chainTypeManager.storedBatchZero(),
                address(addresses.bridgehub),
                address(addresses.interopCenter)
            );

            // Verify chain was deployed
            assertTrue(chain != address(0), "Chain should be deployed at a valid address");
            assertTrue(chain.code.length > 0, "Chain should have contract code");

            address stmAddr = IZKChain(chain).getChainTypeManager();
            assertTrue(stmAddr != address(0), "CTM address should not be zero");

            vm.startBroadcast(owner);
            addresses.bridgehub.addTokenAssetId(baseTokenAssetId);
            addresses.bridgehub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();

            // Verify chain is now registered
            address bridgehubChainAddressForChain = addresses.bridgehub.getZKChain(chainId);
            bytes32 bridgehubBaseAssetIdForChain = addresses.bridgehub.baseTokenAssetId(chainId);
            address bhAddr = IZKChain(chain).getBridgehub();

            assertEq(bridgehubChainAddressForChain, chain, "Chain address should be registered in bridgehub");
            assertEq(bridgehubBaseAssetIdForChain, baseTokenAssetId, "Base token asset ID should be set");
            assertEq(bhAddr, address(addresses.bridgehub), "Bridgehub address should match");
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
