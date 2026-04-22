#!/usr/bin/env node
/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires */

const blakejs = require("blakejs");
const fs = require("fs");

function hexToBytes(hex) {
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
  const inputFile = args[1];
  if (!inputFile) {
    console.error("Usage: blake2s256.js --batch <input-file>");
    process.exit(1);
  }
  const lines = fs.readFileSync(inputFile, "utf-8").split("\n").filter(Boolean);
  let output = "";
  for (const line of lines) {
    output += blakejs.blake2sHex(hexToBytes(line.trim()));
  }
  console.log("0x" + output);
} else {
  const input = args.join(" ");
  if (!input) {
    console.error("Usage: blake2s256.js <hex-string>");
    process.exit(1);
  }
  console.log(blakejs.blake2sHex(hexToBytes(input)));
}
