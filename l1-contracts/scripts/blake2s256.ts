#!/usr/bin/env ts-node

import {blake2s} from './utils';

// Grab the input from the command-line arguments (excluding node and script path)
const input = process.argv.slice(2).join(" ");
if (!input) {
  console.error("Usage: blake2s-hash <your text>");
  process.exit(1);
}

const hash = blake2s(input);

// Output, skipping the "0x" prefix
console.log(hash.slice(2));
