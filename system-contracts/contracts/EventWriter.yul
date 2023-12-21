/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract responsible for decoding and writing events using low-level instructions.
 * @dev The metadata and topics are passed via registers, and the first accessible register contains their number.
 * The rest of the data is passed via calldata without copying.
 */
object "EventWriter" {
    code {
        return(0, 0)
    }
    object "EventWriter_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////
            
            // For the documentation of the helper functions, please refer to 
            // the corresponding functions in the SystemContractHelper.sol.

            /// @notice Returns the 0-th extraAbiParam for the current call.
            /// @dev It is equal to the value of the 2-th register at the start of the call.
            function getExtraAbiData_0() -> extraAbiData {
                extraAbiData := verbatim_0i_1o("get_global::extra_abi_data_0")
            }

            /// @notice Returns the 1-th extraAbiParam for the current call.
            /// @dev It is equal to the value of the 3-th register at the start of the call.
            function getExtraAbiData_1() -> extraAbiData {
                extraAbiData := verbatim_0i_1o("get_global::extra_abi_data_1")
            }

            /// @notice Returns the 2-th extraAbiParam for the current call.
            /// @dev It is equal to the value of the 4-th register at the start of the call.
            function getExtraAbiData_2() -> extraAbiData {
                extraAbiData := verbatim_0i_1o("get_global::extra_abi_data_2")
            }

            /// @notice Returns the 3-th extraAbiParam for the current call.
            /// @dev It is equal to the value of the 5-th register at the start of the call.
            function getExtraAbiData_3() -> extraAbiData {
                extraAbiData := verbatim_0i_1o("get_global::extra_abi_data_3")
            }

            /// @notice Returns the 4-th extraAbiParam for the current call.
            /// @dev It is equal to the value of the 6-th register at the start of the call.
            function getExtraAbiData_4() -> extraAbiData {
                extraAbiData := verbatim_0i_1o("get_global::extra_abi_data_4")
            }

            /// @notice Returns the call flags for the current call.
            /// @dev Call flags is the value of the first register at the start of the call.
            /// @dev The zero bit of the callFlags indicates whether the call is
            /// a constructor call. The first bit of the callFlags indicates whether
            /// the call is a system one.
            function getCallFlags() -> ret {
                ret := verbatim_0i_1o("get_global::call_flags")
            }

            /// @notice Initialize a new event
            /// @param initializer The event initializing value
            /// @param value1 The first topic or data chunk.
            function eventInitialize(initializer, value1) {
                verbatim_2i_0o("event_initialize", initializer, value1)
            }

            /// @notice Continue writing the previously initialized event.
            /// @param value1 The first topic or data chunk.
            /// @param value2 The second topic or data chunk.
            function eventWrite(value1, value2) {
                verbatim_2i_0o("event_write", value1, value2)
            }
            
            // @dev Write 1-th topic and first data chunk
            function writeFirstTopicWithDataChunk() {
                let topic1 := getExtraAbiData_1()
                let dataChunk := calldataload(0)
                eventWrite(topic1, dataChunk)
            }

            // @dev Write 1-th and 2-th event topics 
            function writeFirstTwoTopics() {
                let topic1 := getExtraAbiData_1()
                let topic2 := getExtraAbiData_2()
                eventWrite(topic1, topic2)
            }

            // @dev Write 3-th topic and first data chunk
            function writeThirdTopicWithDataChunk() {
                let topic3 := getExtraAbiData_3()
                let dataChunk := calldataload(0)
                eventWrite(topic3, dataChunk)
            }

            // @dev Write 3-th and 4-th event topics 
            function writeSecondTwoTopics() {
                let topic3 := getExtraAbiData_3()
                let topic4 := getExtraAbiData_4()
                eventWrite(topic3, topic4)
            }

            // @dev Reverts the call if a caller hasn't set the "isSystem" flag before calling
            // Note: this method is different from the `onlySystemCall` modifier that is used in system contracts.
            function onlySystemCall() {
                let callFlags := getCallFlags()
                let isSystemCall := and(callFlags, 2)

                if iszero(isSystemCall) {
                    revert(0, 0)
                }
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////
            
            // Ensure that contract is called on purpose
            onlySystemCall()

            let numberOfTopics := getExtraAbiData_0()
            // Only 4 indexed fields are allowed, same as on EVM
            if gt(numberOfTopics, 4) {
                revert(0, 0)
            }
            
            let dataLength := calldatasize()
            // Increment number of topics to include the `msg.sender` as a topic
            let initializer := add(shl(32, dataLength), add(numberOfTopics, 1))
            eventInitialize(initializer, caller())

            // Save the pointer to written data
            let dataCursor

            // Handle every case separately, to save gas on loops (alternative approach)
            switch numberOfTopics
                case 0 {
                    // Nothing to publish
                }
                case 1 {
                    writeFirstTopicWithDataChunk()
                    dataCursor := add(dataCursor, 0x20)
                }
                case 2 {
                    writeFirstTwoTopics()
                }
                case 3 { 
                    writeFirstTwoTopics()
                    writeThirdTopicWithDataChunk()
                    dataCursor := add(dataCursor, 0x20)
                }
                case 4 { 
                    writeFirstTwoTopics()
                    writeSecondTwoTopics()
                }
                default {
                    // Unreachable
                    revert(0, 0)
                }

            // Write all the event data, two words at a time
            for {} lt(dataCursor, dataLength) {
                dataCursor := add(dataCursor, 0x40)
            } {
                let chunk1 := calldataload(dataCursor)
                let chunk2 := calldataload(add(dataCursor, 0x20))
                eventWrite(chunk1, chunk2)
            }
        }
    }
}
