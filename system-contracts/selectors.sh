#!/bin/bash

# Define the directory and output file
CONTRACTS_DIR="./contracts"
OUTPUT_FILE="sysSelectors.txt"

# Ensure the output file is empty before appending
> "$OUTPUT_FILE"

# Iterate over all .sol files in the contracts directory
for file in "$CONTRACTS_DIR"/*.sol; do
  if [[ -f $file ]]; then
    echo "Processing $file..."
    forge selectors list --contracts "$file" >> "$OUTPUT_FILE"
  else
    echo "No .sol files found in $CONTRACTS_DIR"
  fi
done

echo "Selectors have been written to $OUTPUT_FILE"