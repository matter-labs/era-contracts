#!/bin/bash

# Function to modify JSON string by changing "address" to "addr" and returning logs array
modify_json_address() {
    local json_string="$1"
    local index="$2"
    
    # Use jq to extract logs array, then use sed to replace "address" with "addr" and "type" with "txType"
    # Extract logs array and apply the field replacements
    echo "$json_string" | jq '.result.logs | map(.data)' | jq ".[$index]" | sed -e 's/"address":/"addr":/g' -e 's/"type":/"txType":/g' | jq 'walk(if type == "string" and test("^0x[0-9a-fA-F]+$") then if (length < 66) then "0x" + ("0" * (64 - (length - 2))) + .[2:] else . end else . end) | {data: .}'
}

# Check if JSON string is provided as argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <json_string>"
    echo "Example: $0 '{\"address\": \"0x123...\", \"value\": 100}'"
    exit 1
fi

# Get the JSON string from the first argument
json_string="$1"
index="$2"


# Call the function and output the result
modify_json_address "$json_string" "$index"

