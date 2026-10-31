use schemars::Schema;
use schemars::generate::SchemaSettings;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use texlocal_latex::messages;
use texlocal_latex::protocol::Described;
use texlocal_latex::syntax::{HighlightKind, Source, Syntax};

use crate::CoreError;
use crate::events::Said;
use crate::service::{Library, LibrarySection};
use crate::session::{Session, SessionSection};

mod digest;

pub use digest::DIGEST;

pub(crate) type Answer<T> = fn(Result<T, CoreError>) -> Result<Value, CoreError>;

pub(crate) fn answer<T: Serialize>(result: Result<T, CoreError>) -> Result<Value, CoreError> {
    result.map(|value| json!(value))
}

pub(crate) fn arguments<T: DeserializeOwned>(args: Value) -> Result<T, CoreError> {
    serde_json::from_value(args)
        .map_err(|err| CoreError::bad_request(messages::invalid_arguments(err)))
}

pub(crate) fn unknown() -> CoreError {
    CoreError::not_found(messages::unknown_command())
}

pub struct Protocol {
    pub requests: Vec<Described>,
    pub stores: Vec<Schema>,
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
    requests.extend(Source::describe(&mut inbound, &mut outbound));
    requests.extend(Syntax::describe(&mut inbound, &mut outbound));
    outbound.subschema_for::<HighlightKind>();
    outbound.subschema_for::<Said>();
    let stores = vec![
        outbound.subschema_for::<SessionSection>(),
        outbound.subschema_for::<LibrarySection>(),
    ];
    Protocol {
        requests,
        stores,
        inbound: inbound.take_definitions(true),
        outbound: outbound.take_definitions(true),
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
            ) -> Vec<texlocal_latex::protocol::Described> {
                vec![$(texlocal_latex::protocol::describe::<$request, $reply>(
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
