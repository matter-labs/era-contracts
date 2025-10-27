#!/usr/bin/env ts-node

import * as blakejs from "blakejs";

// Helper to convert a hex string to Uint8Array
function hexToBytes(hex: string): Uint8Array {
  if (hex.startsWith("0x")) hex = hex.slice(2);
  if (hex.length % 2 !== 0) {
    throw new Error("Invalid hex string");
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

// Grab the input from the command-line arguments (excluding node and script path)
const input = process.argv.slice(2).join(" ");
if (!input) {
  console.error("Usage: blake2s-hash <your text>");
  process.exit(1);
}

// Convert input hex to bytes
const inputBytes = hexToBytes(input);

// Compute the BLAKE2s hash
const hash = blakejs.blake2sHex(inputBytes);

// Output
console.log(hash);
