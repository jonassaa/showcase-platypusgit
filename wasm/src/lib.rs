//! A markdown inline lexer, compiled to WebAssembly.
//!
//! The experiment this branch exists to settle: the TypeScript lexer walks the
//! string one code unit at a time and allocates a token object per span. On a
//! 40 KB note that is measurable. Rust can walk bytes and hand back one flat
//! buffer, so the JavaScript side allocates once instead of per token.
//!
//! Whether that is worth a Rust toolchain in the build is the open question.
//! It is not obviously yes: the JS lexer is 0.06 ms on a real note.

#![no_std]

extern crate alloc;

use alloc::vec::Vec;

/// What a span is. Kept as a u8 because it crosses the wasm boundary in a byte
/// buffer, and an enum with a stable discriminant is the cheapest encoding
/// that both sides can agree on.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Text = 0,
    Code = 1,
    Strong = 2,
    Em = 3,
}

/// One lexed span: kind, then byte offsets into the original input.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Span {
    pub kind: Kind,
    pub start: usize,
    pub end: usize,
}

/// Find the closing run of `delim` after `from`, or None.
fn close(bytes: &[u8], from: usize, delim: u8, len: usize) -> Option<usize> {
    let mut i = from;
    while i + len <= bytes.len() {
        if bytes[i..i + len].iter().all(|b| *b == delim) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Lex inline markup into spans.
///
/// Code spans win: a `**` inside backticks is text, which is the rule people
/// notice when a renderer gets it wrong. Offsets are BYTES, not code units —
/// the caller has to slice the original `&str`, not a UTF-16 view of it.
pub fn lex_inline(input: &str) -> Vec<Span> {
    let bytes = input.as_bytes();
    let mut out: Vec<Span> = Vec::new();
    let mut text_start = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        let (delim, len, kind) = match bytes[i] {
            b'`' => (b'`', 1, Kind::Code),
            b'*' if i + 1 < bytes.len() && bytes[i + 1] == b'*' => (b'*', 2, Kind::Strong),
            b'*' => (b'*', 1, Kind::Em),
            _ => {
                i += 1;
                continue;
            }
        };

        match close(bytes, i + len, delim, len) {
            Some(end) if end > i + len => {
                if i > text_start {
                    out.push(Span { kind: Kind::Text, start: text_start, end: i });
                }
                out.push(Span { kind, start: i + len, end });
                i = end + len;
                text_start = i;
            }
            _ => i += len,
        }
    }

    if text_start < bytes.len() {
        out.push(Span { kind: Kind::Text, start: text_start, end: bytes.len() });
    }
    out
}

/// A classified line.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Block {
    Blank = 0,
    Heading = 1,
    Item = 2,
    Quote = 3,
    Fence = 4,
    Line = 5,
}

/// Classify one line. Byte-wise on purpose: every marker markdown cares about
/// is ASCII, so there is no reason to decode UTF-8 to find them.
pub fn classify(line: &str) -> (Block, u8) {
    let b = line.as_bytes();
    let first = b.iter().position(|c| *c != b' ' && *c != b'\t');
    let Some(start) = first else {
        return (Block::Blank, 0);
    };

    match b[start] {
        b'#' => {
            let level = b[start..].iter().take_while(|c| **c == b'#').count();
            if level <= 6 && b.get(start + level) == Some(&b' ') {
                (Block::Heading, level as u8)
            } else {
                (Block::Line, 0)
            }
        }
        b'>' => (Block::Quote, 0),
        b'-' | b'*' if b.get(start + 1) == Some(&b' ') => (Block::Item, 0),
        b'0'..=b'9' => {
            let digits = b[start..].iter().take_while(|c| c.is_ascii_digit()).count();
            match b.get(start + digits) {
                Some(b'.') | Some(b')') => (Block::Item, 1),
                _ => (Block::Line, 0),
            }
        }
        b'`' if b[start..].starts_with(b"```") => (Block::Fence, 0),
        _ => (Block::Line, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_span_beats_emphasis() {
        let spans = lex_inline("`**not bold**`");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, Kind::Code);
    }

    #[test]
    fn classifies_the_markers_we_care_about() {
        assert_eq!(classify("").0, Block::Blank);
        assert_eq!(classify("## two"), (Block::Heading, 2));
        assert_eq!(classify("- a").0, Block::Item);
        assert_eq!(classify("1. a"), (Block::Item, 1));
        assert_eq!(classify("> q").0, Block::Quote);
        assert_eq!(classify("```ts").0, Block::Fence);
        assert_eq!(classify("plain").0, Block::Line);
    }

    #[test]
    fn a_hash_without_a_space_is_not_a_heading() {
        assert_eq!(classify("#tag").0, Block::Line);
    }
}
