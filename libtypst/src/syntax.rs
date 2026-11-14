//! Queries over the upstream parser. No secondary Typst lexer is maintained.
use crate::abi::{
    TypstMemberUse, TypstStr, TYPST_MEMBER_USES_REBOUND, TYPST_MEMBER_USES_WHOLE,
    TYPST_SYNTAX_CODE, TYPST_SYNTAX_MARKUP, TYPST_SYNTAX_MATH,
};
use crate::error::Error;
use typst_core::syntax::{ast, ast::AstNode, LinkedNode, SyntaxKind, SyntaxMode, SyntaxNode};

pub(crate) fn syntax_mode(syntax: u32) -> Result<SyntaxMode, Error> {
    match syntax {
        TYPST_SYNTAX_MARKUP => Ok(SyntaxMode::Markup),
        TYPST_SYNTAX_CODE => Ok(SyntaxMode::Code),
        TYPST_SYNTAX_MATH => Ok(SyntaxMode::Math),
        _ => Err(Error::invalid("unknown Typst syntax mode")),
    }
}

/// The places where code reads a member of one name, found in the upstream
/// syntax tree. Records borrow the member names this value owns.
pub(crate) struct MemberUses {
    /// Owns the member names, read only through the views in `records`.
    #[allow(dead_code)]
    names: Vec<typst_core::ecow::EcoString>,
    records: Vec<TypstMemberUse>,
    flags: u32,
}

// Records point only into `names`, which this value owns and never mutates.
unsafe impl Send for MemberUses {}
unsafe impl Sync for MemberUses {}

impl MemberUses {
    pub(crate) fn records(&self) -> &[TypstMemberUse] {
        &self.records
    }

    pub(crate) fn flags(&self) -> u32 {
        self.flags
    }
}

/// Every `name.member` in code, markup and math, and every member listed in
/// `import name: …`, in source order. Members reached through another value,
/// such as `let m = name; m.x`, are not uses of `name`. The flags tell whether
/// the source binds the name itself and whether it uses it as a whole value.
pub(crate) fn member_uses(source: &str, mode: SyntaxMode, name: &str) -> MemberUses {
    let root = match mode {
        SyntaxMode::Markup => typst_core::syntax::parse(source),
        SyntaxMode::Code => typst_core::syntax::parse_code(source),
        SyntaxMode::Math => typst_core::syntax::parse_math(source),
    };
    let mut uses = Uses {
        name,
        found: Vec::new(),
        rebound: false,
        whole: false,
        accounted: Vec::new(),
    };
    uses.visit(&LinkedNode::new(&root));
    let names: Vec<typst_core::ecow::EcoString> = uses
        .found
        .iter()
        .map(|(member, _)| member.clone())
        .collect();
    let records = names
        .iter()
        .zip(&uses.found)
        .map(|(member, (_, range))| TypstMemberUse {
            member: TypstStr::view(member.as_str()),
            start: range.start,
            end: range.end,
        })
        .collect();
    let mut flags = 0;
    if uses.rebound {
        flags |= TYPST_MEMBER_USES_REBOUND;
    }
    if uses.whole {
        flags |= TYPST_MEMBER_USES_WHOLE;
    }
    MemberUses {
        names,
        records,
        flags,
    }
}

type Found = Vec<(typst_core::ecow::EcoString, std::ops::Range<usize>)>;

/// What one walk over the tree learns about a name.
struct Uses<'a> {
    name: &'a str,
    found: Found,
    rebound: bool,
    whole: bool,
    /// Occurrences of the name that do not read it as a whole value: owners
    /// of recorded members, bindings of the name, and the names of fields,
    /// pairs and imported items. A parent accounts for them before the walk
    /// reaches them; any other occurrence is a whole-value use.
    accounted: Vec<*const SyntaxNode>,
}

impl Uses<'_> {
    fn visit(&mut self, node: &LinkedNode) {
        if let Some(access) = node.cast::<ast::FieldAccess>() {
            if let ast::Expr::Ident(target) = access.target() {
                if target.get() == self.name {
                    self.accounted.push(target.to_untyped());
                    record(node, access.field().to_untyped(), &mut self.found);
                }
            }
            self.account(access.field().to_untyped());
        } else if let Some(access) = node.cast::<ast::MathFieldAccess>() {
            if let ast::MathAccess::MathIdent(target) = access.target() {
                if target.get() == self.name {
                    self.accounted.push(target.to_untyped());
                    record(node, access.field().to_untyped(), &mut self.found);
                }
            }
            self.account(access.field().to_untyped());
        } else if let Some(import) = node.cast::<ast::ModuleImport>() {
            let source = match import.source() {
                ast::Expr::Ident(source) if source.get() == self.name => Some(source),
                _ => None,
            };
            if let Some(alias) = import.new_name() {
                self.bind(alias);
            }
            if let Some(ast::Imports::Items(items)) = import.imports() {
                for item in items.iter() {
                    // An item's path names members of the imported module.
                    for part in item.path().iter() {
                        self.account(part.to_untyped());
                    }
                    self.bind(item.bound_name());
                    if let (Some(source), Some(first)) = (source, item.path().iter().next()) {
                        self.accounted.push(source.to_untyped());
                        record(node, first.to_untyped(), &mut self.found);
                    }
                }
            }
        } else if let Some(binding) = node.cast::<ast::LetBinding>() {
            match binding.kind() {
                ast::LetBindingKind::Normal(pattern) => self.bind_pattern(pattern),
                ast::LetBindingKind::Closure(ident) => self.bind(ident),
            }
        } else if let Some(closure) = node.cast::<ast::Closure>() {
            if let Some(ident) = closure.name() {
                self.bind(ident);
            }
            for param in closure.params().children() {
                match param {
                    ast::Param::Pos(pattern) => self.bind_pattern(pattern),
                    ast::Param::Named(named) => self.bind(named.name()),
                    ast::Param::Spread(spread) => {
                        if let Some(sink) = spread.sink_ident() {
                            self.bind(sink);
                        }
                    }
                }
            }
        } else if let Some(each) = node.cast::<ast::ForLoop>() {
            self.bind_pattern(each.pattern());
        } else if let Some(named) = node.cast::<ast::Named>() {
            self.account(named.name().to_untyped());
        } else if matches!(node.kind(), SyntaxKind::Ident | SyntaxKind::MathIdent)
            && node.get().leaf_text().as_str() == self.name
            && !self
                .accounted
                .iter()
                .any(|known| std::ptr::eq(*known, node.get()))
        {
            self.whole = true;
        }
        for child in node.children() {
            self.visit(&child);
        }
    }

    /// `ident` is not a whole-value use of the name, whatever it names.
    fn account(&mut self, ident: &SyntaxNode) {
        if ident.leaf_text().as_str() == self.name {
            self.accounted.push(ident);
        }
    }

    fn bind(&mut self, ident: ast::Ident) {
        if ident.get() == self.name {
            self.rebound = true;
            self.accounted.push(ident.to_untyped());
        }
    }

    fn bind_pattern(&mut self, pattern: ast::Pattern) {
        for ident in pattern.bindings() {
            self.bind(ident);
        }
    }
}

/// Records the identifier `target`, found among the descendants of `node`.
fn record(node: &LinkedNode, target: &SyntaxNode, found: &mut Found) {
    if let Some(linked) = find(node, target) {
        found.push((target.leaf_text().clone(), linked.range()));
    }
}

fn find<'a>(node: &LinkedNode<'a>, target: &SyntaxNode) -> Option<LinkedNode<'a>> {
    if std::ptr::eq(node.get(), target) {
        return Some(node.clone());
    }
    node.children().find_map(|child| find(&child, target))
}

pub(crate) fn source_block(source: &str) -> Result<usize, Error> {
    let (desired, left, right) = match source.as_bytes().first() {
        Some(b'[') => (
            SyntaxKind::ContentBlock,
            SyntaxKind::LeftBracket,
            SyntaxKind::RightBracket,
        ),
        Some(b'{') => (
            SyntaxKind::CodeBlock,
            SyntaxKind::LeftBrace,
            SyntaxKind::RightBrace,
        ),
        _ => {
            return Err(Error::invalid(
                "source must begin with a Typst content or code block",
            ))
        }
    };
    let root = typst_core::syntax::parse_code(source);
    let mut node: &SyntaxNode = &root;
    while node.kind() != desired {
        node = node
            .children()
            .find(|node| !node.is_empty())
            .ok_or_else(|| Error::new(crate::abi::TYPST_COMPILE_FAILED, "unclosed Typst block"))?;
    }
    let mut children = node.children();
    if children.next().is_none_or(|node| node.kind() != left)
        || children.next_back().is_none_or(|node| node.kind() != right)
    {
        return Err(Error::new(
            crate::abi::TYPST_COMPILE_FAILED,
            "unclosed Typst block",
        ));
    }
    Ok(node.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_block_boundaries_ignore_host_suffix_and_keep_nested_typst_syntax() {
        for (source, prefix) in [
            (
                "[héllo [nested] #\"end\"]\nexport x",
                "[héllo [nested] #\"end\"]",
            ),
            ("{ let x = [a]; x } ; end", "{ let x = [a]; x }"),
        ] {
            assert_eq!(source_block(source).unwrap(), prefix.len());
        }
        assert!(source_block("[unclosed").is_err());
        assert!(source_block("{ let x = [missing").is_err());
        assert!(source_block("plain").is_err());
    }

    fn uses(source: &str, mode: SyntaxMode) -> (Vec<(String, &str)>, u32) {
        let found = member_uses(source, mode, "lib");
        let records = found
            .records()
            .iter()
            .map(|record| {
                let member = unsafe {
                    std::str::from_utf8(std::slice::from_raw_parts(
                        record.member.data,
                        record.member.len,
                    ))
                }
                .unwrap()
                .to_owned();
                (member, &source[record.start..record.end])
            })
            .collect();
        (records, found.flags())
    }

    #[test]
    fn member_uses_cover_markup_code_math_and_import_items_in_source_order() {
        let members =
            "#lib.title \"lib.no\" // lib.no\n$ lib.mark(\"a\", a) + lib.x $ #{ lib.f(1).g }\n\
                      #import lib: alpha, beta as b\n#other.no";
        let (found, flags) = uses(members, SyntaxMode::Markup);
        let names: Vec<_> = found.iter().map(|(member, _)| member.as_str()).collect();
        assert_eq!(
            names,
            ["title", "mark", "x", "f", "alpha", "beta"],
            "{found:?}"
        );
        for (member, text) in &found {
            assert_eq!(member, text, "ranges cover the member identifier");
        }
        assert_eq!(flags, 0);
        // Whole-value uses name no member.
        let source = format!("{members}\n#import lib: *\n#lib");
        let (with_whole, flags) = uses(&source, SyntaxMode::Markup);
        assert_eq!(with_whole.len(), found.len());
        assert_eq!(flags, TYPST_MEMBER_USES_WHOLE);
        let (found, _) = uses("[#lib.long_member_name_beyond_inline]", SyntaxMode::Code);
        assert_eq!(found[0].1, "long_member_name_beyond_inline");
    }

    #[test]
    fn member_uses_report_when_the_code_binds_the_name_itself() {
        for source in [
            "#let lib = (a: 1); #lib.a",
            "#let f(lib) = lib.a",
            "#for lib in () {}",
            "#import \"x.typ\" as lib",
            "#import other: lib",
            "#let g = (..lib) => 1",
            "#let (a, lib) = (1, 2)",
            "#let h(lib: 1) = 2",
        ] {
            assert_eq!(
                uses(source, SyntaxMode::Markup).1,
                TYPST_MEMBER_USES_REBOUND,
                "{source}"
            );
        }
        assert_eq!(uses("#let f(x) = lib.a + x", SyntaxMode::Markup).1, 0);
        // The bound name read as a whole value is reported as such too.
        assert_eq!(
            uses("#let g = (..lib) => lib", SyntaxMode::Markup).1,
            TYPST_MEMBER_USES_REBOUND | TYPST_MEMBER_USES_WHOLE
        );
    }

    #[test]
    fn member_uses_report_whole_value_uses_apart_from_members_names_and_text() {
        for (source, mode) in [
            ("#lib", SyntaxMode::Markup),
            ("#repr(dictionary(lib))", SyntaxMode::Markup),
            ("#import lib: *", SyntaxMode::Markup),
            ("#import lib", SyntaxMode::Markup),
            ("#include lib", SyntaxMode::Markup),
            ("#let m = lib", SyntaxMode::Markup),
            ("#f(..lib)", SyntaxMode::Markup),
            ("#(lib,)", SyntaxMode::Markup),
            ("#lib.a #lib", SyntaxMode::Markup),
            ("$ lib $", SyntaxMode::Markup),
            ("f(lib)", SyntaxMode::Code),
            ("f(lib)", SyntaxMode::Math),
        ] {
            assert_eq!(uses(source, mode).1, TYPST_MEMBER_USES_WHOLE, "{source}");
        }
        for source in [
            "#lib.a",
            "#import lib: a",
            "#x.lib",
            "#f(lib: 1)",
            "#(lib: 1)",
            "#import \"x.typ\": lib as other",
            "\"lib\" lib // lib",
            "#\"lib\"",
            "$ other.lib + \"lib\" $",
            "<lib> @lib",
        ] {
            assert_eq!(uses(source, SyntaxMode::Markup).1, 0, "{source}");
        }
    }
}
