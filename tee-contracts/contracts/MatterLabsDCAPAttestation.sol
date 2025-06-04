// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AttestationEntrypointBase} from "automata-network/dcap-attestation/evm/contracts/AttestationEntrypointBase.sol";
import {AutomataDaoStorage} from "@automata-network/on-chain-pccs/automata_pccs/shared/AutomataDaoStorage.sol";
import {AutomataEnclaveIdentityDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataEnclaveIdentityDao.sol";
import {AutomataFmspcTcbDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataFmspcTcbDao.sol";
import {AutomataPckDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPckDao.sol";
import {AutomataPcsDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPcsDao.sol";
import {BELE} from "automata-network/dcap-attestation/evm/contracts/utils/BELE.sol";
import {CA} from "@automata-network/on-chain-pccs/Common.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EnclaveIdentityJsonObj} from "@automata-network/on-chain-pccs/helpers/EnclaveIdentityHelper.sol";
import {HEADER_LENGTH, SGX_TEE, TDX_TEE} from "automata-network/dcap-attestation/evm/contracts/types/Constants.sol";
import {PCCSRouter} from "automata-network/dcap-attestation/evm/contracts/PCCSRouter.sol";
import {PCCSRouter} from "automata-network/dcap-attestation/evm/contracts/PCCSRouter.sol";
import {TcbInfoJsonObj} from "@automata-network/on-chain-pccs/helpers/FmspcTcbHelper.sol";
import {IHashValidator, EmptyArray} from "./interfaces/IHashValidator.sol";

/**
 * @title MatterLabs DCAP Attestation
 * @dev Contract for handling attestation and verification using DCAP
 */
contract MatterLabsDCAPAttestation is AttestationEntrypointBase {
    error InvalidP256Verifier();
    error InvalidHashValidator();
    error IncorrectVersion(uint256 version);
    error InvalidSigner(address recoveredSigner);
    error InvalidMrEnclave(bytes32 mrEnclave);
    error InvalidTD10ReportBodyMrHash(bytes32 tD10ReportBodyMrHash);
    error VerificationFailed(bytes output);
    error ArrayLengthMismatch();

    uint256 private constant SIGNER_ARRAY_SIZE = 50;
    uint256 private currentSignerIndex;
    uint256 private totalSigners;
    address[SIGNER_ARRAY_SIZE] private signers;

    using ECDSA for bytes32;

    uint256 constant MR_ENCLAVE_OFFSET = HEADER_LENGTH + 64;
    uint256 constant ENCLAVE_REPORT_DATA_OFFSET = HEADER_LENGTH + 320;
    uint256 constant TD10_MRTD_OFFSET = HEADER_LENGTH + 136;
    uint256 constant TD10_RTMR0_OFFSET = HEADER_LENGTH + 328;
    uint256 constant TD10_RTMR1_OFFSET = TD10_RTMR0_OFFSET + 48;
    uint256 constant TD10_RTMR2_OFFSET = TD10_RTMR1_OFFSET + 48;
    uint256 constant TD10_RTMR3_OFFSET = TD10_RTMR2_OFFSET + 48;
    uint256 constant TD10_REPORT_DATA_OFFSET = HEADER_LENGTH + 520;

    address P256_VERIFIER;
    AutomataDaoStorage pccsStorage;
    AutomataPcsDao pcsDao;
    AutomataPckDao pckDao;
    AutomataEnclaveIdentityDao enclaveIdDao;
    AutomataFmspcTcbDao fmspcTcbDao;

    PCCSRouter public pccsRouter;
    IHashValidator hashValidator;

    /**
     * @dev Initializes the contract with the P256 verifier, Helpers, DAOs, and Enclave Hash Validator.
     * @param _P256_Verifier Address of the P256 Verifier contract.
     * @param _hashValidator Address of the Enclave Hash Validator contract.
     * @param _pccsStorage Address of the pre-deployed AutomataDaoStorage
     * @param _pcsDao Address of the pre-deployed AutomataPcsDao
     * @param _pckDao Address of the pre-deployed AutomataPckDao
     * @param _enclaveIdDao Address of the pre-deployed AutomataEnclaveIdentityDao
     * @param _fmspcTcbDao Address of the pre-deployed AutomataFmspcTcbDao
     * @param _pccsRouter Address of the pre-deployed PCCSRouter
     */
    constructor(
        address _P256_Verifier,
        address _hashValidator,
        address _pccsStorage,
        address _pcsDao,
        address _pckDao,
        address _enclaveIdDao,
        address _fmspcTcbDao,
        address _pccsRouter
    ) {
        require(_P256_Verifier.code.length > 0, InvalidP256Verifier());
        P256_VERIFIER = _P256_Verifier;

        require(_hashValidator.code.length > 0, InvalidHashValidator());
        hashValidator = IHashValidator(_hashValidator);
        pccsStorage = AutomataDaoStorage(_pccsStorage);
        pcsDao = AutomataPcsDao(_pcsDao);
        pckDao = AutomataPckDao(_pckDao);
        enclaveIdDao = AutomataEnclaveIdentityDao(_enclaveIdDao);
        fmspcTcbDao = AutomataFmspcTcbDao(_fmspcTcbDao);
        pccsRouter = PCCSRouter(_pccsRouter);
    }

    /**
     * @notice Verifies and attests a TEE (Trusted Execution Environment) quote on-chain
     * @dev Processes quotes from both SGX and TDX TEE types, with different handling based on quote version
     * @param rawQuote The raw attestation quote data from the TEE
     * @param digest The message digest that was signed by the enclave
     * @param signature The signature of the digest created by the enclave signer
     * @custom:throws InvalidMrEnclave when the enclave measurement doesn't match allowed values
     * @custom:throws InvalidTD10ReportBodyMrHash when the TD10 report hash is invalid
     * @custom:throws IncorrectVersion when the quote version is incorrect
     * @custom:throws InvalidSigner when signature verification fails
     * @custom:throws VerificationFailed when on-chain attestation verification fails
     */
    function verifyAndAttestOnChain(bytes calldata rawQuote, bytes32 digest, bytes calldata signature) external view {
        uint16 quoteVersion = uint16(BELE.leBytesToBeUint(rawQuote[0:2]));
        bytes4 teeType = bytes4(uint32(BELE.leBytesToBeUint(rawQuote[4:8])));
        if (quoteVersion == 3 || (quoteVersion == 4 && teeType == SGX_TEE)) {
            _checkMrEnclave(rawQuote);
            uint256 reportDataOffset = ENCLAVE_REPORT_DATA_OFFSET;
            _checkSigner(rawQuote, digest, signature, reportDataOffset);
        } else if (quoteVersion == 4 && teeType == TDX_TEE) {
            _checkTD10Mr(rawQuote);
            uint256 reportDataOffset = TD10_REPORT_DATA_OFFSET;
            _checkSigner(rawQuote, digest, signature, reportDataOffset);
        }

        (bool success, bytes memory output) = _verifyAndAttestOnChain(rawQuote);
        require(success, VerificationFailed(output));
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
    function registerSigner(bytes calldata rawQuote) external {
        address signer;
        uint16 quoteVersion = uint16(BELE.leBytesToBeUint(rawQuote[0:2]));
        bytes4 teeType = bytes4(uint32(BELE.leBytesToBeUint(rawQuote[4:8])));
        if (quoteVersion == 3 || (quoteVersion == 4 && teeType == SGX_TEE)) {
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

        if (totalSigners < SIGNER_ARRAY_SIZE) {
            totalSigners++;
        }
        signers[currentSignerIndex] = signer;
        currentSignerIndex = (currentSignerIndex + 1) % SIGNER_ARRAY_SIZE;
    }

    /**
     * @notice Verifies that a message digest was signed by a registered TEE signer
     * @dev Recovers the signer address from the signature and checks against the list of registered signers
     * @param digest The message digest that was signed
     * @param signature The signature to verify
     * @custom:throws InvalidSigner when the signature was not created by a registered signer
     */
    function verifyDigest(bytes32 digest, bytes calldata signature) external view {
        address recovered = digest.recover(signature);
        bool signerFound = false;
        for (uint i = 0; i < totalSigners; i++) {
            if (recovered == signers[i]) {
                signerFound = true;
                break;
            }
        }
        require(signerFound, InvalidSigner(recovered));
    }

    function _checkMrEnclave(bytes calldata rawQuote) internal view {
        bytes32 mrEnclave = bytes32(rawQuote[MR_ENCLAVE_OFFSET:MR_ENCLAVE_OFFSET + 32]);
        require(hashValidator.isValidEnclaveHash(mrEnclave), InvalidMrEnclave(mrEnclave));
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

    function updateP256Verifier(address _P256_VERIFIER) external onlyOwner {
        require(_P256_VERIFIER.code.length > 0, InvalidP256Verifier());
        P256_VERIFIER = _P256_VERIFIER;
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
    ) external {
        enclaveIdDao.upsertEnclaveIdentity(id, quoteVersion, identityJson);
    }

    /**
     * @notice Upserts FMSPC TCB info into the DAO
     * @param tcbInfoJson The TCB info JSON object
     */
    function upsertFmspcTcb(TcbInfoJsonObj calldata tcbInfoJson) external {
        fmspcTcbDao.upsertFmspcTcb(tcbInfoJson);
    }

    // ============Resolver Config Functions============

    /**
     * @notice Sets the caller authorization for the resolver
     * @param caller The address of the caller
     * @param authorized Whether the caller is authorized
     */
    function setResolverCallerAuthorization(address caller, bool authorized) external onlyOwner {
        pccsStorage.setCallerAuthorization(caller, authorized);
    }

    /**
     * @notice Pauses the resolver caller restriction
     */
    function pauseResolverCallerRestriction() external onlyOwner {
        pccsStorage.pauseCallerRestriction();
    }

    /**
     * @notice Unpauses the resolver caller restriction
     */
    function unpauseResolverCallerRestriction() external onlyOwner {
        pccsStorage.unpauseCallerRestriction();
    }

    /**
     * @notice Updates the DAO addresses in the resolver
     * @param _pcsDao The address of the PCS DAO
     * @param _pckDao The address of the PCK DAO
     * @param _fmspcTcbDao The address of the FMSPC TCB DAO
     * @param _enclaveIdDao The address of the enclave ID DAO
     */
    function updateResolverDao(
        address _pcsDao,
        address _pckDao,
        address _fmspcTcbDao,
        address _enclaveIdDao
    ) external onlyOwner {
        pccsStorage.updateDao(_pcsDao, _pckDao, _fmspcTcbDao, _enclaveIdDao);
    }

    /**
     * @notice Revokes a DAO in the resolver
     * @param revoked The address of the DAO to revoke
     */
    function revokeResolverDao(address revoked) external onlyOwner {
        pccsStorage.revokeDao(revoked);
    }

    // ============Router Config Functions============

    /**
     * @notice Sets the authorization for the router
     * @param caller The address of the caller
     * @param authorized Whether the caller is authorized
     */
    function setRouterAuthorization(address caller, bool authorized) external onlyOwner {
        pccsRouter.setAuthorized(caller, authorized);
    }

    /**
     * @notice Enables the caller restriction for the router
     */
    function enableRouterCallerRestriction() external onlyOwner {
        pccsRouter.enableCallerRestriction();
    }

    /**
     * @notice Disables the caller restriction for the router
     */
    function disableRouterCallerRestriction() external onlyOwner {
        pccsRouter.disableCallerRestriction();
    }

    /**
     * @notice Sets the configuration for the router
     * @param _qeid The address of the QE ID
     * @param _fmspcTcb The address of the FMSPC TCB
     * @param _pcs The address of the PCS
     * @param _pck The address of the PCK
     * @param _x509 The address of the X509
     * @param _x509Crl The address of the X509 CRL
     * @param _tcbHelper The address of the TCB helper
     */
    function setRouterConfig(
        address _qeid,
        address _fmspcTcb,
        address _pcs,
        address _pck,
        address _x509,
        address _x509Crl,
        address _tcbHelper
    ) external onlyOwner {
        pccsRouter.setConfig(_qeid, _fmspcTcb, _pcs, _pck, _x509, _x509Crl, _tcbHelper);
    }
}
