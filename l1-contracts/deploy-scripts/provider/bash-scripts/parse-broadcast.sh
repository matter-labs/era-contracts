#!/bin/bash

# Check if a file path is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <broadcast_file_path>"
    exit 1
fi

broadcast_file="$1"

# Check if the file exists
if [ ! -f "$broadcast_file" ]; then
    echo "Error: File '$broadcast_file' not found"
    exit 1
fi

# Generate output filename by replacing .json with .parsed.json
output_file="${broadcast_file%.json}.parsed.json"

# Use jq to transform the JSON
# Replace "function" with "functionKey", "returns" with "returnValues", remove paymasterData and contractName
jq '
  .transactions |= map(
    if has("function") then 
      . + {"functionKey": .function} | del(.function)
    else . end
  ) |
  .transactions |= map(
    .transaction.zksync |= del(.paymasterData)
  ) |
  .transactions |= map(
    del(.contractName)
  ) |
  if has("returns") then 
    . + {"returnValues": .returns} | del(.returns)
  else . end
' "$broadcast_file" > "$output_file"

# Check if jq transformation was successful
if [ $? -eq 0 ]; then
    echo "Successfully created $output_file"
    echo "Changes made:"
    echo "  - 'function' -> 'functionKey' in transactions"
    echo "  - 'returns' -> 'returnValues' at root level"
    echo "  - Removed 'paymasterData' from transactions.transaction.zksync"
    echo "  - Removed 'contractName' from transactions"
else
    echo "Error: Failed to process JSON file"
    rm -f "$output_file"
    exit 1
fi
