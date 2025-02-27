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
	var inputHex string

	if len(os.Args) != 2 {
		inputHex = ""
	} else {
		inputHex = os.Args[1]
	}

	// Remove "0x" prefix if present
	inputHex = strings.TrimPrefix(inputHex, "0x")

	input, err := hex.DecodeString(inputHex)
	if err != nil {
		fmt.Printf("Error decoding hex input: %v\n", err)
		os.Exit(1)
	}

	result, err := vm.PrecompiledContractsIstanbul[common.BytesToAddress([]byte{0x8})].Run(input) // bn256PairingIstanbul precompile

	if err != nil {
		printError("Error running precompile: "+err.Error(), "PRECOMPILE_ERROR")
		return
	}

	printSuccess("0x" + hex.EncodeToString(result))
}
