use std::collections::BTreeMap;
use std::fmt;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, JsonSchema)]
pub struct Message {
    #[schemars(schema_with = "id")]
    pub id: &'static str,
    pub args: BTreeMap<&'static str, String>,
    pub text: String,
}

fn id(_: &mut SchemaGenerator) -> Schema {
    json_schema!({ "$ref": "#/$defs/MessageID" })
}

impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}

#[macro_export]
macro_rules! messages {
    ($($id:ident $(($($arg:ident),+))? = $text:literal;)*) => {
        $(
            pub fn $id($($($arg: impl std::fmt::Display),+)?) -> $crate::message::Message {
                $($(let $arg = $arg.to_string();)+)?
                $crate::message::Message {
                    id: stringify!($id),
                    text: format!($text $($(, $arg = $arg)+)?),
                    args: [$($((stringify!($arg), $arg)),+)?].into_iter().collect(),
                }
            }
        )*

        pub const CATALOG: &[(&str, &str)] = &[$((stringify!($id), $text)),*];
    };
}
