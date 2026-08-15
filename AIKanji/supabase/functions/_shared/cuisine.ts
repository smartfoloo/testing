/// The CLOSED cuisine vocabulary, shared by the two functions that write it.
///
/// It exists because the two ends of a cuisine preference were speaking different languages and
/// nothing connected them. `llm-assist` emitted whatever the model felt like ("Italian"),
/// `restaurant-search` stored Google's `primaryType` ("japanese_izakaya_restaurant") and Hot
/// Pepper's Japanese `genre.name` (「居酒屋」), and `fn_score_feasible_candidates` compares the two
/// with `&&`, which is exact array overlap. So a cuisine WANT matched nothing, ever: the
/// satisfaction component silently read 0 and an "exclude 中華" preference excluded nothing. The
/// seeded fixture hides it (its `cuisine_tags` are empty) and the web mock's deterministic parser
/// already emits these members, so only the live model + live provider path was broken.
///
/// The members are the ones both clients can already print: `AppCopy.cuisine` in
/// AIKanji/DesignSystem/AppCopy.swift and `CUISINE_WORDS` in web/src/backend/mock.ts. Adding a
/// member here without adding it there gives a tag no UI has a Japanese label for, so keep the
/// three in step.
///
/// Unlike allergens and dietary tags this vocabulary is NOT safety-critical:
/// `fn_candidate_blocking_types` does not list cuisine, so a value that fails to map costs a
/// little ranking accuracy and can never empty the shortlist.
export const CUISINE_TAGS = [
  "chinese",
  "curry",
  "italian",
  "izakaya",
  "japanese",
  "korean",
  "ramen",
  "soba",
  "sushi",
  "yakiniku",
  "yakitori",
] as const;

/// Mirrors `taxonomyToken` in llm-assist: case and the several dash characters are noise, the
/// katakana prolonged sound mark 'ー' is a letter (ラーメン) and is deliberately left alone.
function token(raw: string): string {
  return raw.toLowerCase().replace(/[ 　\-－‐]/g, "_").trim();
}

/// Every spelling we are willing to translate, and the member it means. A Map rather than an
/// object literal so a provider genre called "constructor" resolves to nothing instead of to
/// something inherited from Object.prototype.
///
/// Three sources feed this: the model's own English, Google Places `primaryType` identifiers, and
/// Hot Pepper genre names. Each alias names the SAME cuisine as its member — nothing here is a
/// near-enough guess.
///
/// DELIBERATELY ABSENT: `barbecue_restaurant` (American BBQ is not 焼肉) and `indian_restaurant`
/// (curry is a dish there, not the genre). Mapping either would put a venue in front of a group
/// that asked for something else.
const CUISINE_ALIASES = new Map<string, string>([
  ["yakitori", "yakitori"],
  ["焼き鳥", "yakitori"],
  ["焼鳥", "yakitori"],
  ["やきとり", "yakitori"],
  ["ヤキトリ", "yakitori"],
  ["yakitori_restaurant", "yakitori"],
  ["izakaya", "izakaya"],
  ["居酒屋", "izakaya"],
  ["izakaya_restaurant", "izakaya"],
  ["japanese_izakaya_restaurant", "izakaya"],
  ["japanese", "japanese"],
  ["和食", "japanese"],
  ["日本料理", "japanese"],
  ["japanese_restaurant", "japanese"],
  ["sushi", "sushi"],
  ["寿司", "sushi"],
  ["すし", "sushi"],
  ["鮨", "sushi"],
  ["sushi_restaurant", "sushi"],
  ["yakiniku", "yakiniku"],
  ["焼肉", "yakiniku"],
  ["焼き肉", "yakiniku"],
  ["やきにく", "yakiniku"],
  ["ホルモン", "yakiniku"],
  ["yakiniku_restaurant", "yakiniku"],
  ["ramen", "ramen"],
  ["ラーメン", "ramen"],
  ["らーめん", "ramen"],
  ["ramen_restaurant", "ramen"],
  ["italian", "italian"],
  ["イタリアン", "italian"],
  ["イタリア料理", "italian"],
  ["パスタ", "italian"],
  ["pasta", "italian"],
  ["italian_restaurant", "italian"],
  ["chinese", "chinese"],
  ["中華", "chinese"],
  ["中華料理", "chinese"],
  ["中国料理", "chinese"],
  ["chinese_restaurant", "chinese"],
  ["korean", "korean"],
  ["韓国料理", "korean"],
  ["韓国", "korean"],
  ["korean_restaurant", "korean"],
  ["curry", "curry"],
  ["カレー", "curry"],
  ["curry_restaurant", "curry"],
  ["soba", "soba"],
  ["そば", "soba"],
  ["蕎麦", "soba"],
  ["ソバ", "soba"],
  ["soba_restaurant", "soba"],
  ["soba_noodle_shop", "soba"],
]);

/// Hot Pepper genres arrive compounded — 「イタリアン・フレンチ」, 「焼肉・ホルモン」 — so a genre
/// that names two cuisines is split and each half looked up. The separators are punctuation only;
/// 韓国料理 is one word and stays one word.
const COMPOUND_SEPARATORS = /[・･/／,、]+/;

/// One spelling -> one CUISINE_TAGS member, or null when we cannot say which cuisine it is.
export function canonicalCuisineTag(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  return CUISINE_ALIASES.get(token(raw)) ?? null;
}

/// The list form: maps every value it can, splits compound genre names, drops what it cannot read,
/// and returns a deduped sorted list so the stored order is stable across passes.
export function canonicalCuisineTags(values: readonly unknown[]): string[] {
  const canonical: string[] = [];
  const add = (tag: string) => {
    if (!canonical.includes(tag)) canonical.push(tag);
  };
  for (const value of values) {
    if (typeof value !== "string") continue;
    const direct = canonicalCuisineTag(value);
    if (direct !== null) {
      add(direct);
      continue;
    }
    for (const part of value.split(COMPOUND_SEPARATORS)) {
      const mapped = canonicalCuisineTag(part);
      if (mapped !== null) add(mapped);
    }
  }
  return canonical.sort();
}
