// A really basic test that only sets one memory cell to 1.
object "Bootloader" {
    code {
    }
    object "Bootloader_deployed" {
        code {
            let DUMMY_TEST_CELL := 0x00
            let DUMMY_TEST_VALUE := 0x123123123
            mstore(DUMMY_TEST_CELL, DUMMY_TEST_VALUE)
            // Need to return. Otherwise, the compiler will optimize out 
            // the mstore
            return(0,32)
        }
    }
}
