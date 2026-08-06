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
