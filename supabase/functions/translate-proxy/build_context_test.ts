import { buildGenderContext } from "./index.ts";

Deno.test("buildGenderContext emits speaker and addressee clues", () => {
  const context = buildGenderContext("gender_female", "M");
  const expected =
    "She wrote the following about herself. The following is addressed to him.";
  if (context !== expected) {
    throw new Error(`unexpected context: ${context}`);
  }
});

Deno.test("buildGenderContext omits unknown genders", () => {
  if (buildGenderContext("non_binary", null) !== undefined) {
    throw new Error("unknown speaker gender must not produce a claim");
  }
  if (
    buildGenderContext(undefined, "female") !==
      "The following is addressed to her."
  ) {
    throw new Error("addressee-only context should be preserved");
  }
});
