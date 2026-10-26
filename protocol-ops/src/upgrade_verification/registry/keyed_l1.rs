//! A mocked L1 that answers each read by what it asks — an `eth_call` by its target and calldata,
//! `eth_getCode` by address, `eth_getStorageAt` by address and slot — for a full-path test whose
//! reads are too many, and too dependent on earlier answers, to queue in order the way the
//! `Asserter` tests do. An `eth_call` nobody answered fails like a revert; code and storage nobody
//! set read as empty. Every `eth_call` is logged, so a test can assert which contract a read went
//! to.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};

use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::RpcClient;
use alloy::sol_types::{SolCall, SolValue};
use alloy::transports::{TransportError, TransportFut};
use alloy_json_rpc::{
    ErrorPayload, RequestPacket, Response, ResponsePacket, ResponsePayload, SerializedRequest,
};
use serde_json::value::RawValue;
use serde_json::Value;

#[derive(Clone, Default)]
pub(super) struct KeyedL1(Arc<Mutex<State>>);

#[derive(Default)]
struct State {
    calls: HashMap<(Address, Bytes), Bytes>,
    code: HashMap<Address, Bytes>,
    storage: HashMap<(Address, B256), B256>,
    log: Vec<(Address, Bytes)>,
}

impl KeyedL1 {
    /// A provider over this L1.
    pub(super) fn provider(&self) -> impl Provider {
        ProviderBuilder::new().connect_client(RpcClient::new(self.clone(), true))
    }

    /// `target` answers `call` with `returns`.
    pub(super) fn answer<C: SolCall>(&self, target: Address, call: C, returns: impl SolValue) {
        self.state().calls.insert(
            (target, Bytes::from(call.abi_encode())),
            Bytes::from(returns.abi_encode()),
        );
    }

    /// Code at `address`.
    pub(super) fn code(&self, address: Address, code: &[u8]) {
        self.state()
            .code
            .insert(address, Bytes::copy_from_slice(code));
    }

    /// `address`'s storage `slot` holds `value`.
    pub(super) fn storage(&self, address: Address, slot: B256, value: B256) {
        self.state().storage.insert((address, slot), value);
    }

    /// Whether some `eth_call` to `target` called `C`.
    pub(super) fn called<C: SolCall>(&self, target: Address) -> bool {
        self.state()
            .log
            .iter()
            .any(|(to, data)| *to == target && data.starts_with(&C::SELECTOR))
    }

    /// The selector of every `eth_call` to `target`, in call order.
    pub(super) fn selectors_called_on(&self, target: Address) -> Vec<[u8; 4]> {
        self.state()
            .log
            .iter()
            .filter(|(to, data)| *to == target && data.len() >= 4)
            .map(|(_, data)| data[..4].try_into().unwrap())
            .collect()
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn respond(&self, request: &SerializedRequest) -> Response {
        let params: Value = request
            .params()
            .map(|params| serde_json::from_str(params.get()).expect("params are JSON"))
            .unwrap_or(Value::Null);
        let address = |value: &Value| -> Address {
            value
                .as_str()
                .and_then(|s| s.parse().ok())
                .expect("an address parameter")
        };
        let mut state = self.state();
        let answer = match request.method() {
            "eth_call" => {
                let tx = &params[0];
                let to = address(&tx["to"]);
                let data: Bytes = tx
                    .get("input")
                    .or_else(|| tx.get("data"))
                    .and_then(Value::as_str)
                    .map(|hex| hex.parse().expect("hex calldata"))
                    .unwrap_or_default();
                state.log.push((to, data.clone()));
                state
                    .calls
                    .get(&(to, data))
                    .map(|out| Value::String(out.to_string()))
                    .ok_or("execution reverted: nothing answers this call")
            }
            "eth_getCode" => {
                let code = state.code.get(&address(&params[0])).cloned();
                Ok(Value::String(code.unwrap_or_default().to_string()))
            }
            "eth_getStorageAt" => {
                let slot: U256 = params[1]
                    .as_str()
                    .and_then(|s| s.parse().ok())
                    .expect("a slot parameter");
                let word = state
                    .storage
                    .get(&(address(&params[0]), B256::from(slot)))
                    .copied()
                    .unwrap_or_default();
                Ok(Value::String(format!("{:#x}", U256::from_be_bytes(word.0))))
            }
            _ => Err("the keyed L1 answers only eth_call, eth_getCode and eth_getStorageAt"),
        };
        Response {
            id: request.id().clone(),
            payload: match answer {
                Ok(value) => ResponsePayload::Success(
                    RawValue::from_string(value.to_string()).expect("a JSON value"),
                ),
                Err(why) => {
                    ResponsePayload::Failure(ErrorPayload::internal_error_message(why.into()))
                }
            },
        }
    }
}

impl tower::Service<RequestPacket> for KeyedL1 {
    type Response = ResponsePacket;
    type Error = TransportError;
    type Future = TransportFut<'static>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, packet: RequestPacket) -> Self::Future {
        let response = match packet {
            RequestPacket::Single(request) => ResponsePacket::Single(self.respond(&request)),
            RequestPacket::Batch(requests) => {
                ResponsePacket::Batch(requests.iter().map(|r| self.respond(r)).collect())
            }
        };
        Box::pin(async move { Ok(response) })
    }
}
