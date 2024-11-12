// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {ZkSyncHyperchainStorage, PubdataPricingMode} from "../state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev ChainRegistrar serves as the main point for chain registration.
contract ChainRegistrar is Ownable2StepUpgradeable, ReentrancyGuard {
    /// Address that will be used for deploying l2 contracts
    address l2Deployer;
    /// Bridgehub
    IBridgehub bridgehub;

    /// Chains that has been succesfuly deployed
    mapping(bytes32 => bool) public deployedChains;
    /// Proposal for chain registration
    mapping(bytes32 => ChainConfig) public proposedChains;

    error ProposalNotFound();
    error ChainIsAlreadyDeployed();
    error ChainIsNotYetDeployed();
    error BridgeIsNotRegistered();

    /// @notice new chain is deployed
    event NewChainDeployed(
        uint256 indexed chainId,
        address diamondProxy,
        address chainAdmin
    );

    /// @notice new chain is proposed to register
    event NewChainRegistrationProposal(
        uint256 indexed chainId,
        address author,
        bytes32 key
    );

    /// @notice Shared bridge is registered on l2
    event SharedBridgeRegistered(
        uint256 indexed chainId,
        address l2Address
    );

    /// @notice new chain is deployed
    event L2DeployerChanged(
        address newDeployer
    );


    struct BaseToken {
        address tokenAddress;
        address tokenMultiplierSetter;
        uint128 gasPriceMultiplierNominator;
        uint128 gasPriceMultiplierDenominator;
    }

    struct ChainConfig {
        /// @param Chain id of the new chain should be unique for this bridgehub
        uint256 chainId;
        /// @param pubdataPricingMode How the users will charged for pubdata.
        PubdataPricingMode pubdataPricingMode;
        /// @param baseToken of the chain
        BaseToken baseToken;
        /// @param Operator for making commit txs.
        address commitOperator;
        /// @param Operator for making Prove and Execute transactions
        address operator;
        /// @param Governor of the chain. Ownership of the chain will be transferred to this operator
        address governor;
    }

    constructor(address _bridgehub, address _l2Deployer) {
        bridgehub = IBridgehub(_bridgehub);
        l2Deployer = _l2Deployer;
    }

    /// @notice used to initialize the contract
    function initialize(address _owner) external {
        _transferOwnership(_owner);
    }


    function proposeChainRegistration(ChainConfig calldata config) public {
        bytes32 key = keccak256(abi.encode(msg.sender, config.chainId));
        if (deployedChains[key] || bridgehub.stateTransitionManager(config.chainId) != address(0)) {
            revert ChainIsAlreadyDeployed();
        }
        proposedChains[key] = config;
        // For Deploying L2 contracts on for non ETH based networks, we as bridgehub owners required base token.
        if (config.baseToken.tokenAddress != ETH_TOKEN_ADDRESS) {
            uint256 amount = 1 ether * config.baseToken.gasPriceMultiplierNominator / config.baseToken.gasPriceMultiplierDenominator;
            if (IERC20(config.baseToken.tokenAddress).balanceOf(address(this)) < amount) {
                IERC20(config.baseToken.tokenAddress).transferFrom(msg.sender, l2Deployer, amount);
            }
        }
        emit NewChainRegistrationProposal(config.chainId, msg.sender, key);
    }

    function changeDeployer(address newDeployer) onlyOwner public {
        l2Deployer = newDeployer;
        emit L2DeployerChanged(l2Deployer);
    }

    function getChainConfig(address author, uint256 chainId) public view returns (ChainConfig memory){
        bytes32 key = keccak256(abi.encode(author, chainId));
        return proposedChains[key];
    }


    function chainRegistered(address author, uint256 chainId) onlyOwner public {
        bytes32 key = keccak256(abi.encode(author, chainId));
        ChainConfig memory config = proposedChains[key];
        if (config.chainId == 0) {
            revert ProposalNotFound();
        }

        if (deployedChains[key]) {
            revert ChainIsAlreadyDeployed();
        }
        address stm = bridgehub.stateTransitionManager(chainId);
        if (stm == address(0)) {
            revert ChainIsNotYetDeployed();
        }
        address diamondProxy = IStateTransitionManager(stm).getHyperchain(chainId);
        (bool success, bytes memory returnData) = diamondProxy.call(abi.encodeWithSelector(IGetters.getAdmin.selector));
        require(success);
        address chainAdmin = bytesToAddress(returnData);
        address l2BridgeAddress = bridgehub.sharedBridge().l2BridgeAddress(chainId);
        if (l2BridgeAddress == address(0)) {
            revert BridgeIsNotRegistered();
        }

        emit NewChainDeployed(chainId, diamondProxy, chainAdmin);
        emit SharedBridgeRegistered(chainId, l2BridgeAddress);
        deployedChains[key] = true;
    }

    function bytesToAddress(bytes memory bys) private pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 32))
        }
    }
}