use schemars::generate::SchemaSettings;
use schemars::{JsonSchema, Schema, SchemaGenerator};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

use crate::CoreError;
use crate::events::SessionEvent;
use crate::service::Library;
use crate::session::Session;

pub(crate) type Answer<T> = fn(Result<T, CoreError>) -> Result<Value, CoreError>;

pub(crate) fn answer<T: Serialize>(result: Result<T, CoreError>) -> Result<Value, CoreError> {
    result.map(|value| json!(value))
}

pub(crate) fn arguments<T: DeserializeOwned>(args: Value) -> Result<T, CoreError> {
    serde_json::from_value(args)
        .map_err(|err| CoreError::bad_request(format!("Invalid arguments: {err}")))
}

pub(crate) fn unknown() -> CoreError {
    CoreError::not_found("Unknown command")
}

pub struct Described {
    pub name: &'static str,
    pub group: &'static str,
    pub request: Schema,
    pub reply: Schema,
}

pub struct Protocol {
    pub requests: Vec<Described>,
    pub inbound: Map<String, Value>,
    pub outbound: Map<String, Value>,
}

pub fn protocol() -> Protocol {
    let mut inbound = SchemaSettings::draft2020_12()
        .for_deserialize()
        .into_generator();
    let mut outbound = SchemaSettings::draft2020_12()
        .for_serialize()
        .into_generator();
    let mut requests = Library::describe(&mut inbound, &mut outbound);
    requests.extend(Session::describe(&mut inbound, &mut outbound));
    outbound.subschema_for::<CoreError>();
    outbound.subschema_for::<SessionEvent>();
    Protocol {
        requests,
        inbound: inbound.take_definitions(true),
        outbound: outbound.take_definitions(true),
    }
}

pub(crate) fn describe<Request: JsonSchema, Reply: JsonSchema>(
    name: &'static str,
    group: &'static str,
    inbound: &mut SchemaGenerator,
    outbound: &mut SchemaGenerator,
) -> Described {
    Described {
        name,
        group,
        request: inbound.subschema_for::<Request>(),
        reply: outbound.subschema_for::<Reply>(),
    }
}

macro_rules! requests {
    ($group:ident { $($request:ident { $($(#[$attr:meta])* $field:ident: $type:ty),* $(,)? } -> $reply:ty,)* }) => {
        $(
            #[derive(serde::Deserialize, schemars::JsonSchema)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            pub(crate) struct $request { $($(#[$attr])* $field: $type),* }
        )*

        pub(crate) enum $group {
            $($request($request, $crate::protocol::Answer<$reply>),)*
        }

        impl $group {
            pub(crate) fn parse(name: &str, args: serde_json::Value) -> Result<Self, $crate::CoreError> {
                match name {
                    $(stringify!($request) => Ok(Self::$request(
                        $crate::protocol::arguments(args)?,
                        $crate::protocol::answer,
                    )),)*
                    _ => Err($crate::protocol::unknown()),
                }
            }

            pub(crate) fn describe(
                inbound: &mut schemars::SchemaGenerator,
                outbound: &mut schemars::SchemaGenerator,
            ) -> Vec<$crate::protocol::Described> {
                vec![$($crate::protocol::describe::<$request, $reply>(
                    stringify!($request),
                    stringify!($group),
                    inbound,
                    outbound,
                ),)*]
            }
        }
    };
}

pub(crate) use requests;
