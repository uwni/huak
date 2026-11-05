//! Copies borrowed C value trees into upstream Typst values and scopes.
use super::{required, text, values};
use crate::{abi::*, error::Error};
use typst_core::foundations::{Array, Binding, Dict, IntoValue, Scope, Value};
use typst_core::layout::Abs;

unsafe fn binding_values(
    data: *const TypstBinding,
    count: usize,
    depth: usize,
    budget: &mut usize,
) -> Result<Dict, Error> {
    if (count != 0 && depth > 64) || count > *budget {
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
        let value = unsafe { input_value(input, depth, budget)? };
        result.insert(name.into(), value);
    }
    Ok(result)
}

unsafe fn input_value(
    input: &TypstValueInput,
    depth: usize,
    budget: &mut usize,
) -> Result<Value, Error> {
    if depth > 64 || *budget == 0 {
        return Err(Error::invalid(
            "binding value tree exceeds depth or node limit",
        ));
    }
    *budget -= 1;
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
            if input.item_count > *budget {
                return Err(Error::invalid("binding value tree exceeds node limit"));
            }
            let mut items = Array::new();
            for value in unsafe { values(input.items, input.item_count, "binding array")? } {
                items.push(unsafe { input_value(value, depth + 1, budget)? });
            }
            items.into_value()
        }
        TYPST_VALUE_DICT => {
            unsafe { binding_values(input.bindings, input.binding_count, depth + 1, budget)? }
                .into_value()
        }
        _ => return Err(Error::invalid("unknown binding value kind")),
    })
}

pub(super) unsafe fn bindings(data: *const TypstBinding, count: usize) -> Result<Scope, Error> {
    let mut scope = Scope::new();
    for (name, value) in unsafe { binding_values(data, count, 0, &mut 1_000_000)? } {
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
        unsafe { input_value(value, 0, &mut 1_000_000) }
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
            unsafe { bindings(&missing, 1) }.err().unwrap().status,
            TYPST_INVALID_ARGUMENT
        );
        let leaf = input(TYPST_VALUE_NONE);
        let duplicate = [TypstBinding {
            name: TypstStr::view("same"),
            value: &leaf,
        }; 2];
        assert_eq!(
            unsafe { bindings(duplicate.as_ptr(), 2) }
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
            assert!(unsafe { input_value(&empty, 64, &mut 1) }.is_ok());
            assert_eq!(
                unsafe { input_value(&empty, 65, &mut 1) }
                    .err()
                    .unwrap()
                    .status,
                TYPST_INVALID_ARGUMENT
            );
        }
    }
}
