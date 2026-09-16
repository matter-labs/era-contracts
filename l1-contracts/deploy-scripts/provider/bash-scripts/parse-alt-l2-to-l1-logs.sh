#!/bin/bash

# Function to modify JSON string by changing "address" to "addr" and returning logs array
modify_json_address() {
    local json_string="$1"
    
    # Use jq to extract l2ToL1Logs array, and ensure l1BatchNumber is zero-padded if it's 0
    echo "$json_string" | jq '
        .result.l2ToL1Logs
        | map(
            del(.logType, .removed, .topics, .data, .isService, .l2_shard_id, .is_service)
            | if (has("l1BatchNumber") | not) or (.l1BatchNumber == 0 or .l1BatchNumber == "0x0" or .l1BatchNumber == "0") then
                .l1BatchNumber = "0x0000000000000000000000000000000000000000000000000000000000000000"
            else
                .
            end
            | if (has("transactionLogIndex") | not) then .transactionLogIndex = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("transactionIndex") | not) then .transactionIndex = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("transactionHash") | not) then .transactionHash = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("shardId") | not) then .shardId = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("logIndex") | not) then .logIndex = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("blockNumber") | not) then .blockNumber = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | if (has("blockHash") | not) then .blockHash = "0x0000000000000000000000000000000000000000000000000000000000000000" else . end
            | to_entries | sort_by(.key) | from_entries
        )
    ' \
    | sed -e 's/"address":/"addr":/g' -e 's/"type":/"txType":/g' \
    | jq 'walk(if type == "string" and test("^0x[0-9a-fA-F]+$") then if (length < 66) then "0x" + ("0" * (64 - (length - 2))) + .[2:] else . end else . end) | {l2ToL1Logs: .}'
# if .key == "logIndex" then "l1BatchNumber" elif .key == "l1BatchNumber" then "logIndex" else .key end
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
