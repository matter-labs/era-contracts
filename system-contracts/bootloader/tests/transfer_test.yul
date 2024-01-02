// A really basic test that only sets one memory cell to 1.
object "Bootloader" {
    code {
    }
    object "Bootloader_deployed" {
        code {
            // This test is used to calculate the number of gas required to 
            // do a simple internal transfer 

            function ETH_L2_TOKEN_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000800a
            }
            function BOOTLOADER_FORMAL_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008001
            }

            // Getting the balance of the account in order to make sure 
            // that the decommit of the account has already happened and so
            // the call of the actual transfer is cheaper.
            let myBalance := selfbalance()
            // Storing the value to avoid compiler optimization
            mstore(100, myBalance)

            let gasBeforeCall := gas()
            let transferSuccess := call(
                gas(),
                ETH_L2_TOKEN_ADDR(),
                0,
                0, 
                100,
                0,
                0
            )
            let gasSpent := sub(gasBeforeCall, gas())

            if iszero(transferSuccess) {
                // The transfer should succeed 
                revert(0,0)
            }


            mstore(0, gasSpent)
            return(0, 256)
        }
    }
}
