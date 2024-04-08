const mcl = require("mcl-wasm");
import { BigNumberish } from "ethers";
import { hexlify } from "ethers/lib/utils";

export type mclG2 = any;
export type mclG1 = any;
export type mclFP = any;

export type solG1 = [BigNumberish, BigNumberish];
export type solG2 = [BigNumberish, BigNumberish, BigNumberish, BigNumberish];

export async function init() {
    await mcl.init(mcl.BN_SNARK1);
    mcl.setMapToMode(mcl.BN254);
}

export function g1ToHex(p: mclG1): solG1 {
    p.normalize();
    const x = hexlify(toBigEndian(p.getX()));
    const y = hexlify(toBigEndian(p.getY()));
    return [x, y];
}

export function g2ToHex(p: mclG2): solG2 {
    p.normalize();
    const x = toBigEndian(p.getX());
    const x0 = hexlify(x.slice(32));
    const x1 = hexlify(x.slice(0, 32));
    const y = toBigEndian(p.getY());
    const y0 = hexlify(y.slice(32));
    const y1 = hexlify(y.slice(0, 32));
    return [x0, x1, y0, y1];
}

export function parseG1(solG1: solG1): mclG1 {
    const g1 = new mcl.G1();
    const [x, y] = solG1;
    g1.setStr(`1 ${x} ${y}`, 16);
    return g1;
}

export function parseG2(solG2: solG2): mclG2 {
    const g2 = new mcl.G2();
    const [x0, x1, y0, y1] = solG2;
    g2.setStr(`1 ${x0} ${x1} ${y0} ${y1}`);
    return g2;
}

export function toBigEndian(p: mclFP): Uint8Array {
    // serialize() gets a little-endian output of Uint8Array
    // reverse() turns it into big-endian, which Solidity likes
    return p.serialize().reverse();
}
