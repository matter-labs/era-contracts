import {Language, SYSTEM_CONTRACTS, YulContractDescrption} from "./constants";
import {BigNumber, BigNumberish, BytesLike, ethers} from "ethers";
import * as fs from "fs";
import {hashBytecode} from "zksync-web3/build/src/utils";
import * as hre from 'hardhat';
import {Deployer} from "@matterlabs/hardhat-zksync-deploy";

export interface Dependency {
    name: string;
    bytecodes: BytesLike[];
    address?: string;
}

export interface DeployedDependency {
    name: string;
    bytecodeHashes: string[];
    address?: string;
}

export function readYulBytecode(description: YulContractDescrption) {
    const contractName = description.codeName;
    const path = `contracts/${description.path}/artifacts/${contractName}.yul/${contractName}.yul.zbin`;
    return ethers.utils.hexlify(fs.readFileSync(path));
}

// The struct used to represent the parameters of a forced deployment -- a deployment during upgrade
// which sets a bytecode onto an address. Typically used for updating system contracts.
export interface ForceDeployment {
    // The bytecode hash to put on an address
    bytecodeHash: BytesLike;
    // The address on which to deploy the bytecodehash to
    newAddress: string;
    // Whether to call the constructor
    callConstructor: boolean;
    // The value with which to initialize a contract
    value: BigNumberish;
    // The constructor calldata
    input: BytesLike;
}

export async function outputSystemContracts(): Promise<ForceDeployment[]> {
    const upgradeParamsPromises: Promise<ForceDeployment>[] = Object.values(SYSTEM_CONTRACTS).map(async (systemContractInfo) => {
        let bytecode: string;

        if (systemContractInfo.lang === Language.Yul) {
            bytecode = readYulBytecode(systemContractInfo);
        } else {
            bytecode = (await hre.artifacts.readArtifact(systemContractInfo.codeName)).bytecode;
        }
        const bytecodeHash = hashBytecode(bytecode);

        return {
            bytecodeHash: ethers.utils.hexlify(bytecodeHash),
            newAddress: systemContractInfo.address,
            value: "0",
            input: '0x',
            callConstructor: false
        }
    });

    return await Promise.all(upgradeParamsPromises);
}

// Script that publishes preimages for all the system contracts on zkSync
// and outputs the JSON that can be used for performing the necessary upgrade
const DEFAULT_L2_TX_GAS_LIMIT = 2097152;


// For the given dependencies, returns an array of tuples (bytecodeHash, marker), where 
// for each dependency the bytecodeHash is its versioned hash and marker is whether
// the hash has been published before.
export async function getMarkers(dependencies: BytesLike[], deployer: Deployer): Promise<[string, boolean][]> {
    const contract = new ethers.Contract(
        SYSTEM_CONTRACTS.knownCodesStorage.address,
        (await hre.artifacts.readArtifact('KnownCodesStorage')).abi,
        deployer.zkWallet
    );

    const promises = dependencies.map(async (dep) => {
        const hash = ethers.utils.hexlify(hashBytecode(dep));
        const marker = BigNumber.from(await contract.getMarker(hash));

        return [hash, marker.eq(1)] as [string, boolean];
    });

    return await Promise.all(promises);
}

// Checks whether the marker has been set correctly in the KnownCodesStorage
// system contract
export async function checkMarkers(dependencies: BytesLike[], deployer: Deployer) {
    const markers = await getMarkers(dependencies, deployer);

    for(const [bytecodeHash, marker] of markers) {
        if(!marker) {
            throw new Error(`Failed to mark ${bytecodeHash}`);
        }
    }
}

export function totalBytesLength(dependencies: BytesLike[]): number {
    return dependencies.reduce((prev, curr) => prev + ethers.utils.arrayify(curr).length, 0);
}

export function getBytecodes(dependencies: Dependency[]): BytesLike[] {
    return dependencies.map((dep) => dep.bytecodes).flat();
}

export async function publishFactoryDeps(
    dependencies: Dependency[],
    deployer: Deployer,
    nonce: number,
    gasPrice: BigNumber,
) {
    if(dependencies.length == 0) {
        return [];
    }
    const bytecodes = getBytecodes(dependencies);
    const combinedLength = totalBytesLength(bytecodes);

    console.log(`\nPublishing dependencies for contracts ${dependencies.map((dep) => {return dep.name}).join(', ')}`);
    console.log(`Combined length ${combinedLength}`);

    const txHandle = await deployer.zkWallet.requestExecute({
        contractAddress: ethers.constants.AddressZero,
        calldata: '0x',
        l2GasLimit: DEFAULT_L2_TX_GAS_LIMIT,
        factoryDeps: bytecodes,
        overrides: {
            nonce,
            gasPrice,
            gasLimit: 3000000
        }
    })
    console.log(`Transaction hash: ${txHandle.hash}`);

    // Waiting for the transaction to be processed by the server
    await txHandle.wait();

    console.log('Transaction complete! Checking markers on L2...');

    // Double checking that indeed the dependencies have been marked as known
    await checkMarkers(bytecodes, deployer);
}

// Returns an array of bytecodes that should be published along with their total length in bytes
export async function filterPublishedFactoryDeps(
    contractName: string,
    factoryDeps: string[],
    deployer: Deployer,
): Promise<[string[], number]> {
    console.log(`\nFactory dependencies for contract ${contractName}:`);
    let currentLength = 0;

    let bytecodesToDeploy: string[] = [];

    const hashesAndMarkers = await getMarkers(factoryDeps, deployer);

    for(let i = 0; i < factoryDeps.length; i++) {
        const depLength = ethers.utils.arrayify(factoryDeps[i]).length;
        const [hash, marker] = hashesAndMarkers[i];
        console.log(`${hash} (length: ${depLength} bytes) (deployed: ${marker})`);

        if(!marker) {
            currentLength += depLength;
            bytecodesToDeploy.push(factoryDeps[i]);
        }
    }

    console.log(`Combined length to deploy: ${currentLength}`);

    return [bytecodesToDeploy, currentLength];
}
