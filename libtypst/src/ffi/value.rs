//! Copies borrowed C value trees into upstream Typst values and scopes.
use super::{required, text, values};
use crate::{abi::*, error::Error};
use typst_core::foundations::{Array, Binding, Dict, IntoValue, Module, Scope, Value};
use typst_core::layout::Abs;

/// Values made before a request's bindings, which inputs refer to by index:
/// template functions and the modules of the options' handles.
#[derive(Clone, Copy, Default)]
pub(super) struct References<'a> {
    pub(super) templates: &'a [Value],
    pub(super) handles: &'a [Value],
}

/// Converts one borrowed tree. Template and module-handle inputs refer to the
/// values already made for this request.
struct Conversion<'a> {
    references: References<'a>,
    budget: usize,
}

impl Conversion<'_> {
    unsafe fn bindings(
        &mut self,
        data: *const TypstBinding,
        count: usize,
        depth: usize,
    ) -> Result<Dict, Error> {
        if (count != 0 && depth > 64) || count > self.budget {
            return Err(Error::invalid(
                "binding value tree exceeds depth or node limit",
            ));
        }
        let mut result = Dict::new();
        for binding in unsafe { values(data, count, "bindings")? } {
            let name = unsafe { text(binding.name, "binding name")? };
            if result.contains(name) {
                return Err(Error::invalid(format!("duplicate binding name: {name}")));
            }
            let input = unsafe { required(binding.value, "binding value")? };
            let value = unsafe { self.value(input, depth)? };
            result.insert(name.into(), value);
        }
        Ok(result)
    }

    unsafe fn value(&mut self, input: &TypstValueInput, depth: usize) -> Result<Value, Error> {
        if depth > 64 || self.budget == 0 {
            return Err(Error::invalid(
                "binding value tree exceeds depth or node limit",
            ));
        }
        self.budget -= 1;
        if input.reserved != 0 {
            return Err(Error::invalid("binding value reserved field must be zero"));
        }
        Ok(match input.kind {
            TYPST_VALUE_NONE => Value::None,
            TYPST_VALUE_BOOL if input.integer == 0 || input.integer == 1 => {
                (input.integer != 0).into_value()
            }
            TYPST_VALUE_BOOL => {
                return Err(Error::invalid("boolean binding input must be zero or one"))
            }
            TYPST_VALUE_INT => input.integer.into_value(),
            TYPST_VALUE_FLOAT | TYPST_VALUE_LENGTH if !input.number.is_finite() => {
                return Err(Error::invalid("numeric binding inputs must be finite"))
            }
            TYPST_VALUE_FLOAT => input.number.into_value(),
            TYPST_VALUE_LENGTH => Abs::pt(input.number).into_value(),
            TYPST_VALUE_COLOR => crate::scene::color(input.color)?.into_value(),
            TYPST_VALUE_STRING => unsafe { text(input.text, "binding string")? }.into_value(),
            TYPST_VALUE_ARRAY => {
                if input.item_count > self.budget {
                    return Err(Error::invalid("binding value tree exceeds node limit"));
                }
                let mut items = Array::new();
                for value in unsafe { values(input.items, input.item_count, "binding array")? } {
                    items.push(unsafe { self.value(value, depth + 1)? });
                }
                items.into_value()
            }
            TYPST_VALUE_DICT => {
                unsafe { self.bindings(input.bindings, input.binding_count, depth + 1)? }
                    .into_value()
            }
            TYPST_VALUE_MODULE => {
                let name = unsafe { text(input.text, "module name")? };
                let members =
                    unsafe { self.bindings(input.bindings, input.binding_count, depth + 1)? };
                let mut scope = Scope::new();
                for (member, value) in members {
                    scope.bind(member.into(), Binding::detached(value));
                }
                Value::Module(if name.is_empty() {
                    Module::anonymous(scope)
                } else {
                    Module::new(name, scope)
                })
            }
            TYPST_VALUE_TEMPLATE => usize::try_from(input.integer)
                .ok()
                .and_then(|index| self.references.templates.get(index))
                .cloned()
                .ok_or_else(|| Error::invalid("template binding index is out of range"))?,
            TYPST_VALUE_MODULE_HANDLE => usize::try_from(input.integer)
                .ok()
                .and_then(|index| self.references.handles.get(index))
                .cloned()
                .ok_or_else(|| Error::invalid("module handle binding index is out of range"))?,
            _ => return Err(Error::invalid("unknown binding value kind")),
        })
    }
}

/// Converts one borrowed value, such as a show rule's.
pub(super) unsafe fn value(
    input: &TypstValueInput,
    references: References<'_>,
) -> Result<Value, Error> {
    let mut conversion = Conversion {
        references,
        budget: 1_000_000,
    };
    unsafe { conversion.value(input, 0) }
}

/// `references` are the values already made for this request.
pub(super) unsafe fn bindings(
    data: *const TypstBinding,
    count: usize,
    references: References<'_>,
) -> Result<Scope, Error> {
    let mut conversion = Conversion {
        references,
        budget: 1_000_000,
    };
    let mut scope = Scope::new();
    for (name, value) in unsafe { conversion.bindings(data, count, 0)? } {
        scope.bind(name.into(), Binding::detached(value));
    }
    Ok(scope)
}
#[cfg(test)]
mod tests {
    use super::*;

    fn input(kind: u32) -> TypstValueInput {
        TypstValueInput {
            kind,
            reserved: 0,
            integer: 0,
            number: 0.0,
            text: TypstStr::default(),
            color: TypstColor::default(),
            items: std::ptr::null(),
            item_count: 0,
            bindings: std::ptr::null(),
            binding_count: 0,
        }
    }

    fn converted(value: &TypstValueInput) -> Result<Value, Error> {
        unsafe {
            Conversion {
                references: References::default(),
                budget: 1_000_000,
            }
            .value(value, 0)
        }
    }

    #[test]
    fn template_inputs_select_the_request_templates_by_index() {
        let templates = ["first".into_value(), "second".into_value()];
        let mut reference = input(TYPST_VALUE_TEMPLATE);
        reference.integer = 1;
        let mut conversion = Conversion {
            references: References {
                templates: &templates,
                ..Default::default()
            },
            budget: 8,
        };
        assert_eq!(
            unsafe { conversion.value(&reference, 0) }.unwrap(),
            templates[1]
        );
        for index in [-1, 2] {
            reference.integer = index;
            let error = unsafe { conversion.value(&reference, 0) }.err().unwrap();
            assert_eq!(error.status, TYPST_INVALID_ARGUMENT);
        }
        // Template bindings themselves have no templates to refer to.
        reference.integer = 0;
        assert_eq!(
            converted(&reference).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
    }

    #[test]
    fn module_handle_inputs_select_the_options_handles_by_index() {
        let handles = ["first".into_value(), "second".into_value()];
        let mut reference = input(TYPST_VALUE_MODULE_HANDLE);
        reference.integer = 1;
        let mut conversion = Conversion {
            references: References {
                handles: &handles,
                ..Default::default()
            },
            budget: 8,
        };
        assert_eq!(
            unsafe { conversion.value(&reference, 0) }.unwrap(),
            handles[1]
        );
        for index in [-1, 2] {
            reference.integer = index;
            let error = unsafe { conversion.value(&reference, 0) }.err().unwrap();
            assert_eq!(error.status, TYPST_INVALID_ARGUMENT);
        }
        // Without handles in the options there is nothing to refer to.
        reference.integer = 0;
        assert_eq!(
            converted(&reference).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
    }

    #[test]
    fn input_records_become_native_scalars_lengths_colors_and_owned_collections() {
        let mut integer = input(TYPST_VALUE_INT);
        integer.integer = i64::MIN;
        assert_eq!(converted(&integer).unwrap(), i64::MIN.into_value());
        let mut real = input(TYPST_VALUE_FLOAT);
        real.number = 1.25;
        assert_eq!(converted(&real).unwrap(), 1.25.into_value());
        let mut boolean = input(TYPST_VALUE_BOOL);
        boolean.integer = 1;
        assert_eq!(converted(&boolean).unwrap(), true.into_value());
        let mut length = input(TYPST_VALUE_LENGTH);
        length.number = 18.0;
        assert_eq!(converted(&length).unwrap(), Abs::pt(18.0).into_value());
        let mut color = input(TYPST_VALUE_COLOR);
        color.color = TypstColor {
            r: 0.2,
            g: 0.3,
            b: 0.8,
            a: 1.0,
        };
        assert_eq!(
            converted(&color).unwrap(),
            crate::scene::color(color.color).unwrap().into_value()
        );
        let mut bytes = "Café Ω \"quoted\"\n#panic(\"data only\")"
            .as_bytes()
            .to_vec();
        let mut text = input(TYPST_VALUE_STRING);
        text.text = TypstStr {
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        let leaves = [
            integer,
            real,
            boolean,
            length,
            color,
            text,
            input(TYPST_VALUE_NONE),
        ];
        let mut list = input(TYPST_VALUE_ARRAY);
        list.items = leaves.as_ptr();
        list.item_count = leaves.len();
        let named = [TypstBinding {
            name: TypstStr::view("items"),
            value: &list,
        }];
        let mut dictionary = input(TYPST_VALUE_DICT);
        dictionary.bindings = named.as_ptr();
        dictionary.binding_count = named.len();
        let Value::Dict(owned) = converted(&dictionary).unwrap() else {
            panic!("expected native dictionary")
        };
        bytes.fill(b'x');
        let Value::Array(items) = owned.get("items").unwrap() else {
            panic!("expected native array")
        };
        assert_eq!(items.at(0, None).unwrap(), i64::MIN.into_value());
        assert_eq!(
            items.at(5, None).unwrap(),
            "Café Ω \"quoted\"\n#panic(\"data only\")".into_value()
        );
    }

    #[test]
    fn module_inputs_become_named_or_anonymous_native_modules() {
        let mut count = input(TYPST_VALUE_INT);
        count.integer = 3;
        let members = [TypstBinding {
            name: TypstStr::view("count"),
            value: &count,
        }];
        let mut module = input(TYPST_VALUE_MODULE);
        module.text = TypstStr::view("lib");
        module.bindings = members.as_ptr();
        module.binding_count = members.len();
        let Value::Module(named) = converted(&module).unwrap() else {
            panic!("expected a native module")
        };
        assert_eq!(named.name().map(|name| name.as_str()), Some("lib"));
        assert_eq!(
            *named.scope().get("count").unwrap().read(),
            3i64.into_value()
        );
        module.text = TypstStr::default();
        let Value::Module(anonymous) = converted(&module).unwrap() else {
            panic!("expected a native module")
        };
        assert!(anonymous.name().is_none());
        // Members follow the dictionary rules: names are unique.
        let duplicate = [members[0]; 2];
        module.bindings = duplicate.as_ptr();
        module.binding_count = duplicate.len();
        assert_eq!(
            converted(&module).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
    }

    #[test]
    fn malformed_kind_numbers_strings_and_trees_fail_without_dereferencing_unused_views() {
        let mut bad = input(99);
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        bad = input(TYPST_VALUE_NONE);
        bad.reserved = 1;
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        bad = input(TYPST_VALUE_BOOL);
        bad.integer = 2;
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        for kind in [TYPST_VALUE_FLOAT, TYPST_VALUE_LENGTH] {
            bad = input(kind);
            bad.number = f64::NAN;
            assert_eq!(
                converted(&bad).err().unwrap().status,
                TYPST_INVALID_ARGUMENT
            );
        }
        bad = input(TYPST_VALUE_COLOR);
        bad.color.a = 2.0;
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        bad = input(TYPST_VALUE_STRING);
        bad.text = TypstStr {
            data: b"\xff".as_ptr(),
            len: 1,
        };
        assert_eq!(converted(&bad).err().unwrap().status, TYPST_INVALID_UTF8);
        let missing = TypstBinding {
            name: TypstStr::view("missing"),
            value: std::ptr::null(),
        };
        assert_eq!(
            unsafe { bindings(&missing, 1, References::default()) }
                .err()
                .unwrap()
                .status,
            TYPST_INVALID_ARGUMENT
        );
        let leaf = input(TYPST_VALUE_NONE);
        let duplicate = [TypstBinding {
            name: TypstStr::view("same"),
            value: &leaf,
        }; 2];
        assert_eq!(
            unsafe { bindings(duplicate.as_ptr(), 2, References::default()) }
                .err()
                .unwrap()
                .status,
            TYPST_INVALID_ARGUMENT
        );
        bad = input(TYPST_VALUE_DICT);
        let cycle = TypstBinding {
            name: TypstStr::view("cycle"),
            value: &bad,
        };
        bad.bindings = &cycle;
        bad.binding_count = 1;
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        bad = input(TYPST_VALUE_ARRAY);
        bad.item_count = 1_000_001;
        assert_eq!(
            converted(&bad).err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        for kind in [TYPST_VALUE_ARRAY, TYPST_VALUE_DICT] {
            let empty = input(kind);
            assert!(unsafe {
                Conversion {
                    references: References::default(),
                    budget: 1,
                }
                .value(&empty, 64)
            }
            .is_ok());
            assert_eq!(
                unsafe {
                    Conversion {
                        references: References::default(),
                        budget: 1,
                    }
                    .value(&empty, 65)
                }
                .err()
                .unwrap()
                .status,
                TYPST_INVALID_ARGUMENT
            );
        }
    }
}
