#!/bin/bash

# Function to modify JSON string by changing "address" to "addr"
modify_json_address() {
    local json_string="$1"
    
    # Use sed to replace "address" with "addr" in the JSON string
    # The -e flag allows multiple expressions
    # We need to be careful to only replace "address" when it's a key, not a value
    echo "$json_string" | sed -e 's/"address":/"addr":/g'
}

# Check if JSON string is provided as argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <json_string>"
    echo "Example: $0 '{\"address\": \"0x123...\", \"value\": 100}'"
    exit 1
fi

# Get the JSON string from the first argument
json_string="$1"

# Call the function and output the result
modify_json_address "$json_string"
