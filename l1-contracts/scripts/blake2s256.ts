#!/usr/bin/env ts-node

import * as blakejs from "blakejs";

// Grab the input from the command-line arguments (excluding node and script path)
const input = process.argv.slice(2).join(" ");
if (!input) {
  console.error("Usage: blake2s-hash <your text>");
  process.exit(1);
}

// Compute the BLAKE2s hash
const hash = blakejs.blake2sHex(input);

// Output
console.log(hash);
