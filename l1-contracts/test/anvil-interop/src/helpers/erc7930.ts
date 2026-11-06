/**
 * ERC-7930 InteroperableAddress encoding utilities.
 *
 * Byte layout: version (2B) | chain type (2B) | chain ref len (1B) | chain ref | addr len (1B) | address
 *   version    = 0001
 *   chain type = 0000  (EIP-155)
 *   chain ref  = minimal big-endian encoding of the chain ID
 *   addr len   = 14 (20 bytes) for an EVM address, 00 when omitted
 */

const ERC7930_VERSION = "0001";
const ERC7930_EIP155_CHAIN_TYPE = "0000";

/** Minimal big-endian hex of a chain ID, with the byte-length prefix. */
function encodeChainRef(chainId: number): { len: string; bytes: string } {
  let hex = chainId.toString(16);
  if (hex.length % 2 !== 0) hex = "0" + hex;
  const len = (hex.length / 2).toString(16).padStart(2, "0");
  return { len, bytes: hex };
}

/**
 * Encode a chain ID as an ERC-7930 InteroperableAddress (no address component).
 * Used as the `destinationChain` argument in InteropCenter.sendBundle.
 */
export function encodeEvmChain(chainId: number): string {
  const ref = encodeChainRef(chainId);
  return "0x" + ERC7930_VERSION + ERC7930_EIP155_CHAIN_TYPE + ref.len + ref.bytes + "00";
}

/**
 * Encode a chain-qualified address as an ERC-7930 InteroperableAddress.
 * Used for the `to` field in bundle call starters (recipient on a specific chain).
 */
export function encodeEvmChainAddress(address: string, chainId: number): string {
  const ref = encodeChainRef(chainId);
  return "0x" + ERC7930_VERSION + ERC7930_EIP155_CHAIN_TYPE + ref.len + ref.bytes + "14" + address.slice(2);
}

/**
 * Encode an address as an ERC-7930 InteroperableAddress (no chain reference).
 * Used for bundle attributes (executionAddress, unbundlerAddress) and for
 * callStarters[].to in sendBundle (the destination chain is specified separately
 * in the top-level destinationChain argument, so the `to` field omits it).
 */
export function encodeEvmAddress(address: string): string {
  return "0x" + ERC7930_VERSION + ERC7930_EIP155_CHAIN_TYPE + "00" + "14" + address.slice(2);
}
