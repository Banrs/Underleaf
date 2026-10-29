use std::collections::BTreeMap;

use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq)]
pub enum Ty {
    Bool,
    Int,
    UInt64,
    Double,
    String,
    Data,
    Done,
    List(Box<Self>),
    Map(Box<Self>),
    Optional(Box<Self>),
    Named(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Field {
    pub name: String,
    pub ty: Ty,
    pub required: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Struct(Vec<Field>),
    Units(Vec<(String, Option<String>)>),
    Union(Vec<(String, Option<Ty>)>),
}

pub struct Def {
    pub shape: Shape,
    pub decoded: bool,
    pub encoded: bool,
}

pub struct Request {
    pub name: String,
    pub group: String,
    pub reply: Ty,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Way {
    In,
    Out,
}

#[derive(Default)]
pub struct Ir {
    pub defs: BTreeMap<String, Def>,
    pub requests: Vec<Request>,
    pub stores: Vec<String>,
}

const TAKEN: &[&str] = &[
    "Alignment",
    "Angle",
    "Animation",
    "Any",
    "App",
    "Array",
    "Axis",
    "Binding",
    "Bool",
    "Bundle",
    "Button",
    "Calendar",
    "Character",
    "Color",
    "Data",
    "Date",
    "Dictionary",
    "Divider",
    "Done",
    "Double",
    "Edge",
    "Empty",
    "Environment",
    "Error",
    "Font",
    "Form",
    "Group",
    "Image",
    "Int",
    "Label",
    "Link",
    "List",
    "Locale",
    "Menu",
    "Never",
    "Notification",
    "Optional",
    "Path",
    "Picker",
    "Process",
    "Range",
    "Result",
    "Scene",
    "Section",
    "Set",
    "Settings",
    "Shape",
    "State",
    "String",
    "Tab",
    "Table",
    "Task",
    "Text",
    "Thread",
    "Timer",
    "Toggle",
    "URL",
    "Unit",
    "View",
    "Window",
    "WireKey",
    "WireRequest",
];

impl Ir {
    pub fn add(&mut self, defs: &Map<String, Value>, way: Way) {
        for (name, schema) in defs {
            type_name(name, defs);
            let shape = shape(name, schema, way);
            let def = self.defs.entry(name.clone()).or_insert(Def {
                shape: shape.clone(),
                decoded: false,
                encoded: false,
            });
            match (&mut def.shape, shape) {
                (Shape::Struct(had), Shape::Struct(fields)) => {
                    let names = |fields: &[Field]| {
                        fields
                            .iter()
                            .map(|f| (f.name.clone(), f.ty.clone()))
                            .collect::<Vec<_>>()
                    };
                    assert!(
                        names(had) == names(&fields),
                        "{name} differs between what Swift sends and what it reads"
                    );
                    if way == Way::Out {
                        *had = fields;
                    }
                }
                (had, shape) => assert!(
                    *had == shape,
                    "{name} differs between what Swift sends and what it reads"
                ),
            }
            match way {
                Way::In => def.encoded = true,
                Way::Out => def.decoded = true,
            }
        }
    }

    pub fn request(&mut self, name: &str, group: &str, request: &Value, reply: &Value) {
        let named = ty(request);
        assert!(
            named == Ty::Named(name.into()),
            "the request {name} isn't a struct"
        );
        assert!(
            !self.defs.contains_key(&format!("{group}Request")),
            "{group}Request is a type's name"
        );
        self.requests.push(Request {
            name: name.into(),
            group: group.into(),
            reply: ty(reply),
        });
    }

    pub fn store(&mut self, sections: &Value) {
        let Ty::Named(name) = ty(sections) else {
            panic!("a store's sections aren't a named enum")
        };
        assert!(name.ends_with("Section"), "{name} doesn't end in Section");
        self.stores.push(name);
    }

    pub fn check(&self) {
        for store in &self.stores {
            let Shape::Union(cases) = &self.defs[store].shape else {
                panic!("{store} isn't a tagged union")
            };
            assert!(
                cases.iter().all(|(_, value)| value.is_some()),
                "{store} has a case without a value"
            );
        }
        let mut named = Vec::new();
        for def in self.defs.values() {
            match &def.shape {
                Shape::Struct(fields) => named.extend(fields.iter().map(|f| &f.ty)),
                Shape::Units(_) => {}
                Shape::Union(cases) => named.extend(cases.iter().filter_map(|(_, ty)| ty.as_ref())),
            }
        }
        named.extend(self.requests.iter().map(|r| &r.reply));
        for ty in named {
            if let Some(name) = ty.named() {
                assert!(self.defs.contains_key(name), "{name} has no definition");
            }
        }
    }
}

impl Ty {
    fn named(&self) -> Option<&str> {
        match self {
            Self::List(ty) | Self::Map(ty) | Self::Optional(ty) => ty.named(),
            Self::Named(name) => Some(name),
            _ => None,
        }
    }
}

fn type_name(name: &str, defs: &Map<String, Value>) {
    let mut chars = name.chars();
    assert!(
        chars.next().is_some_and(|c| c.is_ascii_uppercase())
            && chars.all(|c| c.is_ascii_alphanumeric()),
        "{name} isn't a plain type name"
    );
    assert!(
        !TAKEN.contains(&name),
        "{name} is a Swift, SwiftUI or Foundation type's name"
    );
    let base = name.trim_end_matches(|c: char| c.is_ascii_digit());
    assert!(
        base == name || !defs.contains_key(base),
        "two types are named {base}"
    );
}

fn member_name(name: &str, of: &str) -> String {
    let mut chars = name.chars();
    assert!(
        chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && chars.all(|c| c.is_ascii_alphanumeric()),
        "{of}.{name} isn't camelCase"
    );
    name.into()
}

fn object(schema: &Value) -> &Map<String, Value> {
    let Value::Object(schema) = schema else {
        panic!("an untyped value: {schema}")
    };
    const KNOWN: &[&str] = &[
        "$ref",
        "additionalProperties",
        "anyOf",
        "const",
        "contentEncoding",
        "default",
        "enum",
        "format",
        "items",
        "maximum",
        "minimum",
        "oneOf",
        "properties",
        "required",
        "title",
        "type",
        "uniqueItems",
    ];
    if let Some(key) = schema.keys().find(|key| !KNOWN.contains(&key.as_str())) {
        panic!(
            "a shape Swift isn't written for ({key}): {}",
            Value::Object(schema.clone())
        )
    }
    schema
}

pub fn ty(schema: &Value) -> Ty {
    let schema = object(schema);
    if let Some(Value::String(reference)) = schema.get("$ref") {
        let name = reference
            .strip_prefix("#/$defs/")
            .expect("a local reference");
        return Ty::Named(name.into());
    }
    if let Some(Value::Array(options)) = schema.get("anyOf") {
        let [some, none] = options.as_slice() else {
            panic!("an untagged union: {options:?}")
        };
        assert!(
            none == &serde_json::json!({ "type": "null" }),
            "an untagged union: {options:?}"
        );
        return optional(ty(some));
    }
    let kind = match schema.get("type") {
        Some(Value::Array(kinds)) => match kinds.as_slice() {
            [Value::String(kind), Value::String(null)] if null == "null" => {
                let mut one = schema.clone();
                one.insert("type".into(), kind.as_str().into());
                return optional(ty(&Value::Object(one)));
            }
            _ => panic!("a value of several types: {kinds:?}"),
        },
        Some(Value::String(kind)) => kind.as_str(),
        _ => panic!("a value of no type: {}", Value::Object(schema.clone())),
    };
    assert!(
        !schema.contains_key("enum")
            && !schema.contains_key("const")
            && !schema.contains_key("oneOf"),
        "an enum that isn't named"
    );
    match kind {
        "boolean" => Ty::Bool,
        "integer" if schema.get("format") == Some(&"uint64".into()) => Ty::UInt64,
        "integer" => Ty::Int,
        "number" => Ty::Double,
        "string" => match schema.get("contentEncoding") {
            None => Ty::String,
            Some(base64) if base64 == "base64" => Ty::Data,
            Some(other) => panic!("a string encoded as {other}"),
        },
        "null" => Ty::Done,
        "array" => Ty::List(Box::new(ty(&schema["items"]))),
        "object" if !schema.contains_key("properties") => {
            match schema.get("additionalProperties") {
                Some(Value::Bool(_)) | None => panic!("a map of untyped values"),
                Some(values) => Ty::Map(Box::new(ty(values))),
            }
        }
        _ => panic!(
            "a nested struct that isn't named: {}",
            Value::Object(schema.clone())
        ),
    }
}

fn optional(ty: Ty) -> Ty {
    assert!(
        !matches!(ty, Ty::Optional(_) | Ty::Done),
        "an optional that is optional again"
    );
    Ty::Optional(Box::new(ty))
}

fn shape(name: &str, schema: &Value, way: Way) -> Shape {
    let schema = object(schema);
    if let Some(Value::Array(options)) = schema.get("oneOf") {
        return choices(name, options);
    }
    assert!(!schema.contains_key("anyOf"), "{name} is an untagged union");
    match schema.get("type") {
        Some(kind) if kind == "string" => {
            let Some(Value::Array(units)) = schema.get("enum") else {
                panic!("{name} is a string, not a struct or an enum")
            };
            let units = units
                .iter()
                .map(|unit| (member_name(unit.as_str().unwrap(), name), None));
            Shape::Units(units.collect())
        }
        Some(kind) if kind == "object" => fields(name, schema, way),
        _ => panic!("{name} is neither a struct nor an enum"),
    }
}

fn fields(name: &str, schema: &Map<String, Value>, way: Way) -> Shape {
    match schema.get("additionalProperties") {
        Some(Value::Bool(false)) => {}
        None => assert!(
            way == Way::Out,
            "{name} is read by the core without deny_unknown_fields"
        ),
        Some(_) => panic!("{name} keeps unknown fields"),
    }
    let empty = Map::new();
    let properties = match schema.get("properties") {
        Some(Value::Object(properties)) => properties,
        _ => &empty,
    };
    let required = |field: &str| {
        let required = schema.get("required").and_then(Value::as_array);
        required.is_some_and(|required| required.iter().any(|r| r == field))
    };
    let fields = properties.iter().map(|(field, schema)| {
        assert!(field != "type", "{name} has a field named type");
        let field = Field {
            name: member_name(field, name),
            ty: ty(schema),
            required: required(field),
        };
        assert!(field.ty != Ty::Done, "{name}.{} is always null", field.name);
        assert!(
            field.required || matches!(field.ty, Ty::Optional(_)),
            "{name}.{} can be left out but isn't optional",
            field.name
        );
        field
    });
    Shape::Struct(fields.collect())
}

fn choices(name: &str, options: &[Value]) -> Shape {
    let unit = |option: &Value| {
        let option = object(option);
        let (Some(Value::String(unit)), true) = (
            option.get("const"),
            option.get("type") == Some(&"string".into()),
        ) else {
            return None;
        };
        let title = option
            .get("title")
            .map(|title| title.as_str().unwrap().to_owned());
        Some((
            member_name(unit, name),
            Some(title.unwrap_or_else(|| panic!("{name} titles only some cases"))),
        ))
    };
    if let Some(units) = options.iter().map(unit).collect::<Option<Vec<_>>>() {
        return Shape::Units(units);
    }
    let case = |option: &Value| {
        let option = object(option);
        let properties = option.get("properties").and_then(Value::as_object);
        let properties = properties.unwrap_or_else(|| panic!("{name} isn't a tagged union"));
        let tag = properties
            .get("type")
            .and_then(|tag| tag.get("const"))
            .and_then(Value::as_str);
        let tag = tag.unwrap_or_else(|| panic!("{name} isn't tagged by type"));
        let value = properties.get("value").map(ty);
        let keys = properties.len() == 1 + usize::from(value.is_some());
        let required = option.get("required").and_then(Value::as_array);
        let required = required.map_or(0, Vec::len) == properties.len();
        assert!(
            keys && required,
            "{name} isn't adjacently tagged as type and value"
        );
        (member_name(tag, name), value)
    };
    Shape::Union(options.iter().map(case).collect())
}
