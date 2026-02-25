#!/usr/bin/env ts-node

import * as blakejs from "blakejs";
import * as fs from "fs";

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

const args = process.argv.slice(2);

if (args[0] === "--batch") {
  // Batch mode: read hex bytecodes (one per line) from a file,
  // output all 32-byte hashes concatenated as a single 0x-prefixed hex string.
  const inputFile = args[1];
  if (!inputFile) {
    console.error("Usage: blake2s256.ts --batch <input-file>");
    process.exit(1);
  }
  const lines = fs.readFileSync(inputFile, "utf-8").split("\n").filter(Boolean);
  let output = "";
  for (const line of lines) {
    output += blakejs.blake2sHex(hexToBytes(line.trim()));
  }
  console.log("0x" + output);
} else {
  // Single mode: hash hex from CLI args
  const input = args.join(" ");
  if (!input) {
    console.error("Usage: blake2s256.ts <hex-string>");
    process.exit(1);
  }
  console.log(blakejs.blake2sHex(hexToBytes(input)));
}
