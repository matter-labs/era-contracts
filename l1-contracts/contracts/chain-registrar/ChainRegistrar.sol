// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {PubdataPricingMode} from "../state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev ChainRegistrar serves as the main point for chain registration.
contract ChainRegistrar is Ownable2StepUpgradeable, ReentrancyGuard {
    /// @notice Address that will be used for deploying l2 contracts
    address public l2Deployer;
    /// ZKsync Bridgehub
    IBridgehub public bridgehub;

    /// Chains that has been successfully deployed
    mapping(bytes32 => bool) public deployedChains;
    /// Proposal for chain registration
    mapping(bytes32 => ChainConfig) public proposedChains;

    error ProposalNotFound();
    error BaseTokenTransferFailed();
    error ChainIsAlreadyDeployed();
    error ChainIsNotYetDeployed();
    error BridgeIsNotRegistered();

    /// @notice new chain is deployed
    event NewChainDeployed(uint256 indexed chainId, address author, address diamondProxy, address chainAdmin);

    /// @notice new chain is proposed to register
    event NewChainRegistrationProposal(uint256 indexed chainId, address author, bytes32 key);

    /// @notice Shared bridge is registered on l2
    event SharedBridgeRegistered(uint256 indexed chainId, address l2Address);

    /// @notice L2 Deployer has changed
    event L2DeployerChanged(address newDeployer);

    struct BaseToken {
        address tokenAddress;
        address tokenMultiplierSetter;
        uint128 gasPriceMultiplierNominator;
        uint128 gasPriceMultiplierDenominator;
    }

    struct ChainConfig {
        /// @param Chain id of the new chain should be unique for this bridgehub
        uint256 chainId;
        /// @param Operator for making commit txs.
        address blobOperator;
        /// @param Operator for making Prove and Execute transactions
        address operator;
        /// @param Governor of the chain. Ownership of the chain will be transferred to this operator
        address governor;
        /// @param baseToken of the chain
        BaseToken baseToken;
        /// @param pubdataPricingMode How the users will charged for pubdata.
        PubdataPricingMode pubdataPricingMode;
    }

    struct RegisteredChainConfig {
        address pendingChainAdmin;
        address chainAdmin;
        address diamondProxy;
        address l2BridgeAddress;
    }

    // @dev Initialize the contract
    function initialize(address _bridgehub, address _l2Deployer, address _owner) public reentrancyGuardInitializer {
        bridgehub = IBridgehub(_bridgehub);
        l2Deployer = _l2Deployer;
        _transferOwnership(_owner);
    }

    // @dev  Propose a new chain to be registered in zksync ecosystem.
    // ZKsync administration will use this data for registering the chain on bridgehub.
    // The call will fail if the chain already registered.
    // Note: For non eth based chains it requires to either approve equivalent of 1 eth of base token or transfer
    // this token to l2 deployer directly
    function proposeChainRegistration(
        uint256 chainId,
        PubdataPricingMode pubdataPricingMode,
        address blobOperator,
        address operator,
        address governor,
        address tokenAddress,
        address tokenMultiplierSetter,
        uint128 gasPriceMultiplierNominator,
        uint128 gasPriceMultiplierDenominator
    ) public {
        ChainConfig memory config = ChainConfig({
            chainId: chainId,
            pubdataPricingMode: pubdataPricingMode,
            blobOperator: blobOperator,
            operator: operator,
            governor: governor,
            baseToken: BaseToken({
                tokenAddress: tokenAddress,
                tokenMultiplierSetter: tokenMultiplierSetter,
                gasPriceMultiplierNominator: gasPriceMultiplierNominator,
                gasPriceMultiplierDenominator: gasPriceMultiplierDenominator
            })
        });
        bytes32 key = keccak256(abi.encode(msg.sender, config.chainId));
        if (deployedChains[key] || bridgehub.stateTransitionManager(config.chainId) != address(0)) {
            revert ChainIsAlreadyDeployed();
        }
        proposedChains[key] = config;
        // For Deploying L2 contracts on for non ETH based networks, we as bridgehub owners required base token.
        if (config.baseToken.tokenAddress != ETH_TOKEN_ADDRESS) {
            uint256 amount = (1 ether * config.baseToken.gasPriceMultiplierNominator) /
                config.baseToken.gasPriceMultiplierDenominator;
            if (IERC20(config.baseToken.tokenAddress).balanceOf(l2Deployer) < amount) {
                bool success = IERC20(config.baseToken.tokenAddress).transferFrom(msg.sender, l2Deployer, amount);
                if (!success) {
                    revert BaseTokenTransferFailed();
                }
            }
        }
        emit NewChainRegistrationProposal(config.chainId, msg.sender, key);
    }

    // @dev Change l2 deployer
    function changeDeployer(address newDeployer) public onlyOwner {
        l2Deployer = newDeployer;
        emit L2DeployerChanged(l2Deployer);
    }

    function getChainConfig(address author, uint256 chainId) public view returns (ChainConfig memory) {
        bytes32 key = keccak256(abi.encode(author, chainId));
        return proposedChains[key];
    }

    // @dev Get data about the chain that has been fully deployed
    function getRegisteredChainConfig(uint256 chainId) public returns (RegisteredChainConfig memory) {
        address stm = bridgehub.stateTransitionManager(chainId);
        if (stm == address(0)) {
            revert ChainIsNotYetDeployed();
        }
        address diamondProxy = IStateTransitionManager(stm).getHyperchain(chainId);

        address pendingChainAdmin = IGetters(diamondProxy).getPendingAdmin();
        address chainAdmin = IGetters(diamondProxy).getAdmin();
        address l2BridgeAddress = bridgehub.sharedBridge().l2BridgeAddress(chainId);
        if (l2BridgeAddress == address(0)) {
            revert BridgeIsNotRegistered();
        }

        RegisteredChainConfig memory config = RegisteredChainConfig({
            pendingChainAdmin: pendingChainAdmin,
            chainAdmin: chainAdmin,
            diamondProxy: diamondProxy,
            l2BridgeAddress: l2BridgeAddress
        });
        return config;
    }

    // @dev Mark chain as registered. Emit necessary events for spinning up the chain server
    function setChainAsRegistered(address author, uint256 chainId) public onlyOwner nonReentrant {
        bytes32 key = keccak256(abi.encode(author, chainId));
        ChainConfig memory config = proposedChains[key];
        if (config.chainId == 0) {
            revert ProposalNotFound();
        }

        RegisteredChainConfig memory deployedConfig = getRegisteredChainConfig(chainId);

        // Matter Labs team set the pending admin to the chain admin and now governor of the chain must accept ownership
        emit NewChainDeployed(chainId, author, deployedConfig.diamondProxy, deployedConfig.pendingChainAdmin);
        emit SharedBridgeRegistered(chainId, deployedConfig.l2BridgeAddress);
        deployedChains[key] = true;
    }
}
