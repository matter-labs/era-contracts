package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/vm"
)

type Result struct {
	Success   bool   `json:"success"`
	Result    string `json:"result,omitempty"`
	Error     string `json:"error,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}

func printSuccess(result string) {
	output, _ := json.Marshal(Result{Success: true, Result: result})
	fmt.Println(string(output))
}

func printError(message, code string) {
	output, _ := json.Marshal(Result{Success: false, Error: message, ErrorCode: code})
	fmt.Println(string(output))
}

func main() {
	if len(os.Args) != 2 {
		fmt.Println("Usage: go run main.go <128-byte-hex-string>") // two input points, each 32 + 32 bytes (x, y)
		os.Exit(1)
	}

	inputHex := os.Args[1]

	// Remove "0x" prefix if present
	inputHex = strings.TrimPrefix(inputHex, "0x")

	if len(inputHex) != 256 { // 128 bytes = 256 hex characters
		fmt.Println("Input must be a 128-byte (256 character) hex string, optionally prefixed with '0x'")
		os.Exit(1)
	}

	input, err := hex.DecodeString(inputHex)
	if err != nil {
		fmt.Printf("Error decoding hex input: %v\n", err)
		os.Exit(1)
	}

	result, err := vm.PrecompiledContractsIstanbul[common.BytesToAddress([]byte{0x6})].Run(input) // bn256AddIstanbul precompile

	if err != nil {
		printError("Error running precompile: "+err.Error(), "PRECOMPILE_ERROR")
		return
	}

	printSuccess("0x" + hex.EncodeToString(result))
}
