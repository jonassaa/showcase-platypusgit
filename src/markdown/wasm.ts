// The optional Rust lexer.
//
// Nothing here is required for platypad to work. If the artifact is missing, if
// the browser refuses it, or if the fetch fails, `loadWasmLexer` resolves to
// null and `lex.ts` keeps using the TypeScript lexer. That is deliberate: an
// experiment that can break the app when it fails is not an experiment, it is a
// dependency.

import type { Inline } from "./lex.ts";

/** The shape the Rust side exports across the boundary. */
interface LexerExports {
  memory: WebAssembly.Memory;
  lex_inline: (ptr: number, len: number) => number;
  spans_len: () => number;
  alloc: (len: number) => number;
}

const KINDS: Inline["kind"][] = ["text", "code", "strong", "em"];
const SPAN_BYTES = 12; // kind: u32, start: u32, end: u32

let cached: ((text: string) => Inline[]) | null | undefined;

/**
 * Decode the flat span buffer the Rust lexer returns.
 *
 * Offsets from Rust are BYTES into UTF-8. JavaScript strings are UTF-16, so the
 * spans have to be sliced out of the encoded bytes and decoded, never indexed
 * into the original string — getting this wrong is invisible until someone
 * writes an emoji.
 */
function decode(exports: LexerExports, bytes: Uint8Array): Inline[] {
  const view = new DataView(exports.memory.buffer);
  const base = exports.lex_inline(0, bytes.length);
  const count = exports.spans_len();
  const decoder = new TextDecoder();
  const out: Inline[] = [];

  for (let i = 0; i < count; i += 1) {
    const at = base + i * SPAN_BYTES;
    const kind = KINDS[view.getUint32(at, true)] ?? "text";
    const start = view.getUint32(at + 4, true);
    const end = view.getUint32(at + 8, true);
    out.push({ kind, value: decoder.decode(bytes.subarray(start, end)) } as Inline);
  }
  return out;
}

/** The wasm lexer, or null if it is not available. Resolved once. */
export async function loadWasmLexer(): Promise<((text: string) => Inline[]) | null> {
  if (cached !== undefined) return cached;
  cached = null;

  try {
    const response = await fetch("./wasm/platypad-lex.wasm");
    if (!response.ok) return cached;
    const module = await WebAssembly.instantiateStreaming(response, {});
    const exports = module.instance.exports as unknown as LexerExports;
    if (typeof exports.lex_inline !== "function") return cached;

    cached = (text: string): Inline[] => {
      const bytes = new TextEncoder().encode(text);
      const ptr = exports.alloc(bytes.length);
      new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
      return decode(exports, bytes);
    };
  } catch {
    // Any failure at all means "use the TypeScript lexer", which is why this
    // catch is empty and has no business logging.
  }
  return cached;
}
