//! Queries over the upstream parser. No secondary Typst lexer is maintained.
use crate::error::Error;
use typst_core::syntax::{SyntaxKind, SyntaxNode};

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
}
