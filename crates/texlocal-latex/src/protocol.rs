use schemars::{JsonSchema, Schema, SchemaGenerator};

pub struct Described {
    pub name: &'static str,
    pub group: &'static str,
    pub request: Schema,
    pub reply: Schema,
}

pub fn describe<Request: JsonSchema, Reply: JsonSchema>(
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

macro_rules! calls {
    ($group:ident $(($on:ident: $target:ty))? {
        $($request:ident { $($field:ident: $type:ty),* $(,)? } -> $reply:ty = $answer:expr;)*
    }) => {
        $(
            #[derive(serde::Deserialize, schemars::JsonSchema)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct $request { $($field: $type),* }
        )*

        pub struct $group;

        impl $group {
            pub fn call($($on: $target,)? name: &str, args: serde_json::Value) -> Result<serde_json::Value, $crate::message::Message> {
                match name {
                    $(stringify!($request) => {
                        let $request { $($field),* } = serde_json::from_value(args)
                            .map_err($crate::messages::invalid_arguments)?;
                        let reply: $reply = $answer;
                        Ok(serde_json::json!(reply))
                    })*
                    _ => Err($crate::messages::unknown_command()),
                }
            }

            pub fn describe(
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

pub(crate) use calls;
