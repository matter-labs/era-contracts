// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AttestationEntrypointBase} from "automata-network/dcap-attestation/evm/contracts/AttestationEntrypointBase.sol";
import {AutomataDaoStorage} from "@automata-network/on-chain-pccs/automata_pccs/shared/AutomataDaoStorage.sol";
import {AutomataEnclaveIdentityDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataEnclaveIdentityDao.sol";
import {AutomataFmspcTcbDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataFmspcTcbDao.sol";
import {AutomataPcsDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPcsDao.sol";
import {BELE} from "automata-network/dcap-attestation/evm/contracts/utils/BELE.sol";
import {CA} from "@automata-network/on-chain-pccs/Common.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EnclaveIdentityJsonObj} from "@automata-network/on-chain-pccs/helpers/EnclaveIdentityHelper.sol";
import {HEADER_LENGTH, SGX_TEE, TDX_TEE} from "automata-network/dcap-attestation/evm/contracts/types/Constants.sol";
import {TcbInfoJsonObj} from "@automata-network/on-chain-pccs/helpers/FmspcTcbHelper.sol";
import {IHashValidator, EmptyArray} from "./interfaces/IHashValidator.sol";
/**
 * @title MatterLabs DCAP Attestation
 * @dev Contract for handling attestation and verification using DCAP
 */
contract MatterLabsDCAPAttestation is AttestationEntrypointBase {
    error InvalidHashValidator();
    error IncorrectVersion(uint256 version);
    error InvalidSigner(address recoveredSigner);
    error SignerExpired(address signer);
    error InvalidMrEnclave(bytes32 mrEnclave);
    error InvalidMrSigner(bytes32 mrSigner);
    error InvalidTD10ReportBodyMrHash(bytes32 tD10ReportBodyMrHash);
    error VerificationFailed(bytes output);
    error ArrayLengthMismatch();

    uint256 private totalSigners;
    struct SignerInfo{
        bool isRegistered;
        uint256 validUntil;
    }

    mapping(address=>SignerInfo) private signers;

    using ECDSA for bytes32;

    uint256 constant MR_ENCLAVE_OFFSET = HEADER_LENGTH + 64;
    uint256 constant MR_SIGNER_OFFSET = HEADER_LENGTH + 128;
    uint256 constant ENCLAVE_REPORT_DATA_OFFSET = HEADER_LENGTH + 320;
    uint256 constant TD10_MRTD_OFFSET = HEADER_LENGTH + 136;
    uint256 constant TD10_RTMR0_OFFSET = HEADER_LENGTH + 328;
    uint256 constant TD10_RTMR1_OFFSET = TD10_RTMR0_OFFSET + 48;
    uint256 constant TD10_RTMR2_OFFSET = TD10_RTMR1_OFFSET + 48;
    uint256 constant TD10_RTMR3_OFFSET = TD10_RTMR2_OFFSET + 48;
    uint256 constant TD10_REPORT_DATA_OFFSET = HEADER_LENGTH + 520;

    AutomataPcsDao pcsDao;
    AutomataEnclaveIdentityDao enclaveIdDao;
    AutomataFmspcTcbDao fmspcTcbDao;

    IHashValidator hashValidator;

    address operatorAddress;

    event SignerRegistered(address indexed signer, uint256 TTL);
    event SignerUpdated(address indexed signer, uint256 newTTL);
    event SignerDeregistered(address[] signer);

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner() || msg.sender == operatorAddress, "Not authorized");
        _;
    }

    /**
     * @dev Initializes the contract with the Helpers, DAOs, and Enclave Hash Validator.
     * @param owner, Owner of the contract
     * @param _hashValidator Address of the Enclave Hash Validator contract.
     * @param _pcsDao Address of the pre-deployed AutomataPcsDao
     * @param _enclaveIdDao Address of the pre-deployed AutomataEnclaveIdentityDao
     * @param _fmspcTcbDao Address of the pre-deployed AutomataFmspcTcbDao
     */
    constructor(
        address owner, //operator
        address _hashValidator,
        address _pcsDao,
        address _enclaveIdDao,
        address _fmspcTcbDao,
        address _operator_address
    ) AttestationEntrypointBase(owner) {
        hashValidator = IHashValidator(_hashValidator);
        pcsDao = AutomataPcsDao(_pcsDao);
        enclaveIdDao = AutomataEnclaveIdentityDao(_enclaveIdDao);
        fmspcTcbDao = AutomataFmspcTcbDao(_fmspcTcbDao);
        operatorAddress = _operator_address;
    }

    /**
     * @notice Registers a new signer from a valid TEE quote
     * @dev Extracts the signer from the quote after verifying its authenticity
     * @param rawQuote The raw attestation quote data from the TEE
     * @custom:throws InvalidMrEnclave when the enclave measurement doesn't match allowed values
     * @custom:throws InvalidTD10ReportBodyMrHash when the TD10 report hash is invalid
     * @custom:throws IncorrectVersion when the quote version is incorrect
     * @custom:throws VerificationFailed when on-chain attestation verification fails
     */
    function registerSigner(bytes calldata rawQuote) external onlyOwnerOrOperator {
        address signer;
        uint16 quoteVersion = uint16(BELE.leBytesToBeUint(rawQuote[0:2]));
        bytes4 teeType = bytes4(rawQuote[4:8]);
        if ((quoteVersion == 3 || quoteVersion == 4) && teeType == SGX_TEE) {
            _checkMrEnclave(rawQuote);
            uint256 reportDataOffset = ENCLAVE_REPORT_DATA_OFFSET;
            signer = _extractSigner(rawQuote, reportDataOffset);
        } else if (quoteVersion == 4 && teeType == TDX_TEE) {
            _checkTD10Mr(rawQuote);
            uint256 reportDataOffset = TD10_REPORT_DATA_OFFSET;
            signer = _extractSigner(rawQuote, reportDataOffset);
        }

        (bool success, bytes memory output) = _verifyAndAttestOnChain(rawQuote);
        require(success, VerificationFailed(output));

        uint256 signerTTLExpiry = hashValidator.signerTTLExpiry();
        uint256 validUntil = block.timestamp + signerTTLExpiry;
        if(!signers[signer].isRegistered){
            signers[signer] = SignerInfo({
                isRegistered: true,
                validUntil: validUntil
            }); 
            totalSigners++;
            emit SignerRegistered(signer, validUntil);
        } else{
            signers[signer].validUntil = validUntil;
            emit SignerUpdated(signer, validUntil);
        }   
    }

    /**
     * @notice Deregisters an existing signer
     * @param _signers The signers which needs to be deregistered
     * @custom:throws InvalidMrEnclave when the enclave measurement doesn't match allowed values
     */
    function deregisterSigner(address[] memory _signers) external onlyOwnerOrOperator {
        uint256 signersLength = _signers.length;
        for (uint256 i; i<signersLength; ++i){
            address signer = _signers[i];
            if(signers[signer].isRegistered){
                delete signers[signer];
                totalSigners--;
            }
        }
        emit SignerDeregistered(_signers);

    }

    function isSignerExpired(address _signer) public view returns(bool){
        SignerInfo memory signer = signers[_signer];
        require(signer.isRegistered, InvalidSigner(_signer));
        return signer.validUntil < block.timestamp;
    }
    /**
     * @notice Verifies that a message digest was signed by a registered TEE signer
     * @dev Recovers the signer address from the signature and checks against the list of registered signers
     * @param digest The message digest that was signed
     * @param signature The signature to verify
     * @custom:throws InvalidSigner when the signature was not created by a registered signer
     */
    function verifyDigest(bytes32 digest, bytes calldata signature) external view{
        address signer = digest.recover(signature);
        if(isSignerExpired(signer)) revert SignerExpired(signer);
    }

    function _checkMrEnclave(bytes calldata rawQuote) internal view {
        bytes32 mrEnclave = bytes32(rawQuote[MR_ENCLAVE_OFFSET:MR_ENCLAVE_OFFSET + 32]);
        bytes32 mrSigner = bytes32(rawQuote[MR_SIGNER_OFFSET:MR_SIGNER_OFFSET + 32]);
        bool isValidEnclaveHash = hashValidator.isValidEnclaveHash(mrEnclave);
        bool isValidEnclaveSigner = hashValidator.isValidEnclaveSigner(mrSigner);
        require(isValidEnclaveHash || isValidEnclaveSigner, InvalidMrEnclave(mrEnclave));
    }

    function _checkTD10Mr(bytes calldata rawQuote) internal view {
        bytes32 tD10ReportBodyMrHash = keccak256(
            abi.encodePacked(
                rawQuote[TD10_MRTD_OFFSET:TD10_MRTD_OFFSET + 48], //mrTD
                rawQuote[TD10_RTMR0_OFFSET:TD10_RTMR3_OFFSET + 48] //rtMr0, rtMr1, rtMr2, rtMr3
            )
        );
        require(
            hashValidator.isValidTD10ReportBodyMrHash(tD10ReportBodyMrHash),
            InvalidTD10ReportBodyMrHash(tD10ReportBodyMrHash)
        );
    }

    function _extractSigner(bytes calldata rawQuote, uint256 reportDataOffset) internal pure returns (address) {
        address signer = address(bytes20(rawQuote[reportDataOffset:reportDataOffset + 32]));
        uint256 version = uint256(bytes32(rawQuote[reportDataOffset + 32:reportDataOffset + 64]));
        require(version == 1, IncorrectVersion(version));
        return signer;
    }

    function _checkSigner(
        bytes calldata rawQuote,
        bytes32 digest,
        bytes calldata signature,
        uint256 reportDataOffset
    ) internal view {
        address signer = address(bytes20(rawQuote[reportDataOffset:reportDataOffset + 32]));
        uint256 version = uint256(bytes32(rawQuote[reportDataOffset + 32:reportDataOffset + 64]));
        require(version == 1, IncorrectVersion(version));
        address recovered = digest.recover(signature);
        require(recovered == signer, InvalidSigner(recovered));
    }


    function updateHashValidator(address _hashValidator) external onlyOwner {
        require(_hashValidator.code.length > 0, InvalidHashValidator());
        hashValidator = IHashValidator(_hashValidator);
    }

    // ============Functions to upsert Certificates to DAOs============

    /**
     * @notice Upserts Root certificate into the DAO
     * @param cert The certificate data
     * @return attestationId The ID of the attestation
     */
    function upsertRootCertificate(bytes calldata cert) external returns (bytes32 attestationId) {
        attestationId = pcsDao.upsertPcsCertificates(CA.ROOT, cert);
    }

    /**
     * @notice Upserts Signing certificate into the DAO
     * @param cert The certificate data
     * @return attestationId The ID of the attestation
     */
    function upsertSigningCertificate(bytes calldata cert) external returns (bytes32 attestationId) {
        attestationId = pcsDao.upsertPcsCertificates(CA.SIGNING, cert);
    }

    /**
     * @notice Upserts Platform certificate into the DAO
     * @param cert The certificate data
     * @return attestationId The ID of the attestation
     */
    function upsertPlatformCertificate(bytes calldata cert) external returns (bytes32 attestationId) {
        attestationId = pcsDao.upsertPcsCertificates(CA.PLATFORM, cert);
    }

    /**
     * @notice Upserts Root CA CRL into the DAO
     * @param rootcacrl The root CA CRL data
     * @return attestationId The ID of the attestation
     */
    function upsertRootCACrl(bytes calldata rootcacrl) external returns (bytes32 attestationId) {
        attestationId = pcsDao.upsertRootCACrl(rootcacrl);
    }

    /**
     * @notice Upserts PCK CRL into the DAO
     * @param ca The CA type
     * @param crl The CRL data
     * @return attestationId The ID of the attestation
     */
    function upsertPckCrl(CA ca, bytes calldata crl) external returns (bytes32 attestationId) {
        attestationId = pcsDao.upsertPckCrl(ca, crl);
    }

    /**
     * @notice Upserts enclave identity into the DAO
     * @param id The ID of the enclave
     * @param quoteVersion The version of the quote
     * @param identityJson The enclave identity JSON object
     */
    function upsertEnclaveIdentity(
        uint256 id,
        uint256 quoteVersion,
        EnclaveIdentityJsonObj calldata identityJson
    ) external returns (bytes32 attestationId) {
        attestationId = enclaveIdDao.upsertEnclaveIdentity(id, quoteVersion, identityJson);
    }

    /**
     * @notice Upserts FMSPC TCB info into the DAO
     * @param tcbInfoJson The TCB info JSON object
     */
    function upsertFmspcTcb(TcbInfoJsonObj calldata tcbInfoJson) external returns (bytes32 attestationId){
        attestationId = fmspcTcbDao.upsertFmspcTcb(tcbInfoJson);
    }

}
