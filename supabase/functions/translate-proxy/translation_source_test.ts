import { isEmojiOrWhitespaceOnly, normalizeSourceHint } from "./index.ts";

Deno.test("normalizeSourceHint accepts DeepL source codes", () => {
  if (normalizeSourceHint("EN-us") !== "en") {
    throw new Error("regional English should normalize to en");
  }
  if (normalizeSourceHint("iw") !== "he") {
    throw new Error("legacy Hebrew should normalize to he");
  }
  if (normalizeSourceHint("in") !== "id") {
    throw new Error("legacy Indonesian should normalize to id");
  }
});

Deno.test("normalizeSourceHint drops unsupported and auto values", () => {
  for (
    const value of ["ts", "st", "pag", "eu", "yi", "auto", "und", "", null]
  ) {
    if (normalizeSourceHint(value) !== undefined) {
      throw new Error(`${String(value)} should not be passed to DeepL`);
    }
  }
});

Deno.test("isEmojiOrWhitespaceOnly skips non-translatable content", () => {
  if (!isEmojiOrWhitespaceOnly(" 😀👍 ")) {
    throw new Error("emoji-only content should skip DeepL");
  }
  if (isEmojiOrWhitespaceOnly("hello")) {
    throw new Error("text must not be treated as emoji-only");
  }
});
