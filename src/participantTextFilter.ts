/**
 * W4-U1.1 participant-text filter.
 *
 * One provider-free, deterministic, backend-authoritative check shared by the
 * two cross-participant text boundaries: requester-authored request text and
 * the helper's optional fulfillment Message. No participant text ever leaves
 * this process — there is no network call, no model, and no external
 * moderation provider anywhere in this file.
 *
 * Posture. This is deliberately NOT a general profanity filter. It refuses
 * only clearly inappropriate cross-participant content:
 *
 * - `identity-slur`: a short list of unambiguous identity-based slurs (plus
 *   the self-harm abbreviation `kys`);
 * - `threat`: first-person violent intent aimed at a second person;
 * - `sexual-abuse`: severe sexual language aimed at a second person;
 * - `targeted-abuse`: abusive language with a second-person target.
 *
 * Ordinary profanity in a legitimate food/order context, slang, unusual food
 * names, links, phone numbers, emails, and unfamiliar vocabulary are never
 * refused: a bare edgy noun matches nothing, and every non-slur rule requires
 * a second-person target, so "Slutty Vegan" and "this is fucking amazing" pass.
 *
 * Strategy (kept simple and auditable on purpose):
 *
 * 1. Fold. NFKC (UAX #15) collapses compatibility forms such as fullwidth and
 *    mathematical alphanumerics; lowercase; NFD with combining marks removed
 *    drops diacritics; default-ignorable and format characters (zero-width
 *    space/joiners, soft hyphen, BOM, word joiner, variation selectors) are
 *    deleted; and a small explicit lookalike table (below) maps the common
 *    Cyrillic, Greek, and small-capital Latin lookalikes to ASCII. The table
 *    is an intentional, reviewable subset of UTS #39 confusables, not the
 *    full skeleton algorithm.
 * 2. Two variants are evaluated: the folded text, and the same text with
 *    leet-style digit/symbol substitution (`0 1 3 4 5 7 @ $ !`). Substitution
 *    only ever offers a second chance; a match still needs a whole term or a
 *    whole phrase, so `5 pieces` and `7UP` cannot become slurs.
 * 3. Slurs match only as WHOLE units, never substrings, so `snigger` and
 *    `Niger` pass. A unit is an alphanumeric token, a whitespace-delimited
 *    chunk with punctuation squashed out (`n.i.g.g.e.r`, `nig-ger`), or a
 *    bounded window inside a run of three or more single letters
 *    (`n i g g e r`, or `a n i g g e r`). Repetition is tolerated
 *    per letter-run from the term's own spelling (`g{2,}` for the double g),
 *    which is why `niggggger` matches but `niger` does not.
 * 4. Masked letters. A whitespace-delimited unit with one or two interior
 *    censor characters (`*`, `#`, `_`), each standing for exactly one letter,
 *    is restored to a term's plain spelling only when it equals that spelling
 *    letter for letter and at least three letters stay visible. A trailing
 *    English possessive (`n*gger's`) does not defeat it. This is not
 *    edit-distance or fuzzy matching: `n*gger` restores, `n*gget` does not.
 * 5. Phrase rules run over the space-joined token stream. Each is a short,
 *    bounded pattern with a second-person target. Threat verbs exclude words
 *    with common benign idioms (`shoot you a text`, `beat you to it`).
 *
 * Ambiguous food-name collision. `faggots` is also a traditional British dish,
 * so refusing the token everywhere would reject a legitimate food name. It is
 * therefore not an unconditional identity term: it is refused only where a
 * second-person target establishes the participant-directed meaning (`you're a
 * faggot`, `you stupid faggots`), and `thank you`/`bring you`/`I ordered you`
 * style indirect objects are excluded — only when the verb and `you` are
 * separated by whitespace alone, so `Ordered, you faggot` stays refused. `ur`
 * is ambiguous with the possessive `your`, so it counts only in the predicate
 * frame `ur a faggot`. The term has no other special handling in any
 * spelling. `fag` has no food reading and stays an unconditional term.
 *
 * Ambiguous shorthand is never targeting evidence by itself. `ya` is not a
 * second-person target (`fuck ya, pizza time` passes); it counts only directly
 * beside a relation noun, with whitespace alone between them (`fuck ya mom`,
 * but not `Fuck ya! Family bucket`).
 *
 * Culinary `retard`. `retard`, `retards`, and `retarded` are also the baking
 * verb for slowing dough fermentation (`cold retarded pizza dough`). A plainly
 * spelled token of that family within three tokens of a dough/fermentation
 * word is read as that verb (see `neutralizeCulinaryRetard`), unless a clear
 * second-person frame (`you're a`, `you stupid`, `ur a`) already aims it at a
 * participant. The bare term, every other context, and every masked, spaced,
 * or leet spelling stay refused.
 *
 * Deliberately not covered, because covering them would need fuzzy or
 * wildcard matching that broadens false positives beyond the accepted
 * boundary: phonetic respellings, reversed text, concatenating adjacent whole
 * words, masked profanity outside the identity list (`f**k you`), masks
 * combined with repeated letters, three or more masks, and non-English
 * lexicons.
 *
 * Privacy. The verdict carries only an opaque category — never the matched
 * text, the triggering term, or an offset — and nothing here logs. Callers
 * must not log or persist participant text alongside a refusal.
 */

export type ParticipantTextCategory =
  | "identity-slur"
  | "threat"
  | "sexual-abuse"
  | "targeted-abuse";

export type ParticipantTextVerdict =
  | { allowed: true }
  | { allowed: false; category: ParticipantTextCategory };

/**
 * Lookalikes folded to ASCII after NFKC/lowercase. Written as escapes with
 * the code point name so every entry can be audited without trusting how a
 * glyph renders.
 */
const LOOKALIKES: ReadonlyArray<readonly [string, string]> = [
  // Cyrillic.
  ["а", "a"], // CYRILLIC SMALL LETTER A
  ["с", "c"], // CYRILLIC SMALL LETTER ES
  ["е", "e"], // CYRILLIC SMALL LETTER IE
  ["і", "i"], // CYRILLIC SMALL LETTER BYELORUSSIAN-UKRAINIAN I
  ["ј", "j"], // CYRILLIC SMALL LETTER JE
  ["к", "k"], // CYRILLIC SMALL LETTER KA
  ["о", "o"], // CYRILLIC SMALL LETTER O
  ["р", "p"], // CYRILLIC SMALL LETTER ER
  ["ѕ", "s"], // CYRILLIC SMALL LETTER DZE
  ["у", "y"], // CYRILLIC SMALL LETTER U
  ["х", "x"], // CYRILLIC SMALL LETTER HA
  ["һ", "h"], // CYRILLIC SMALL LETTER SHHA
  ["ӏ", "l"], // CYRILLIC SMALL LETTER PALOCHKA
  ["ԁ", "d"], // CYRILLIC SMALL LETTER KOMI DE
  ["ԛ", "q"], // CYRILLIC SMALL LETTER QA
  ["ԝ", "w"], // CYRILLIC SMALL LETTER WE
  // Greek.
  ["α", "a"], // GREEK SMALL LETTER ALPHA
  ["ε", "e"], // GREEK SMALL LETTER EPSILON
  ["ι", "i"], // GREEK SMALL LETTER IOTA
  ["κ", "k"], // GREEK SMALL LETTER KAPPA
  ["ν", "v"], // GREEK SMALL LETTER NU
  ["ο", "o"], // GREEK SMALL LETTER OMICRON
  ["ρ", "p"], // GREEK SMALL LETTER RHO
  ["υ", "u"], // GREEK SMALL LETTER UPSILON
  ["χ", "x"], // GREEK SMALL LETTER CHI
  // Latin variants NFKC leaves alone.
  ["ı", "i"], // LATIN SMALL LETTER DOTLESS I
  ["ɑ", "a"], // LATIN SMALL LETTER ALPHA
  ["ɡ", "g"], // LATIN SMALL LETTER SCRIPT G
  // Latin small capitals.
  ["ᴀ", "a"],
  ["ʙ", "b"],
  ["ᴄ", "c"],
  ["ᴅ", "d"],
  ["ᴇ", "e"],
  ["ꜰ", "f"],
  ["ɢ", "g"],
  ["ʜ", "h"],
  ["ɪ", "i"],
  ["ᴊ", "j"],
  ["ᴋ", "k"],
  ["ʟ", "l"],
  ["ᴍ", "m"],
  ["ɴ", "n"],
  ["ᴏ", "o"],
  ["ᴘ", "p"],
  ["ʀ", "r"],
  ["ꜱ", "s"],
  ["ᴛ", "t"],
  ["ᴜ", "u"],
  ["ᴠ", "v"],
  ["ᴡ", "w"],
  ["ʏ", "y"],
  ["ᴢ", "z"],
];

const LOOKALIKE_MAP: ReadonlyMap<string, string> = new Map(LOOKALIKES);

const LEET_MAP: ReadonlyMap<string, string> = new Map([
  ["0", "o"],
  ["1", "i"],
  ["3", "e"],
  ["4", "a"],
  ["5", "s"],
  ["7", "t"],
  ["@", "a"],
  ["$", "s"],
  ["!", "i"],
]);

const COMBINING_MARKS = /\p{M}+/gu;
const INVISIBLE = /[\p{Default_Ignorable_Code_Point}\p{Cf}]+/gu;
const ALNUM_TOKEN = /[a-z0-9]+/g;
const NON_ALNUM = /[^a-z0-9]+/g;

function fold(text: string): string {
  const stripped = text
    .normalize("NFKC")
    .toLowerCase()
    .normalize("NFD")
    .replace(COMBINING_MARKS, "")
    .replace(INVISIBLE, "");
  let folded = "";
  for (const character of stripped) {
    folded += LOOKALIKE_MAP.get(character) ?? character;
  }
  return folded;
}

function applyLeet(folded: string): string {
  let substituted = "";
  for (const character of folded) {
    substituted += LEET_MAP.get(character) ?? character;
  }
  return substituted;
}

/**
 * Identity-slur terms, written in their plain spelling. Each is compiled so
 * that every letter-run may repeat but never shrinks below its own length
 * (`nigger` → `n+i+g{2,}e+r+`), then matched against a WHOLE unit only.
 * `suffix` is an optional raw regex fragment for plural/inflected forms.
 *
 * Intentionally omitted because each has a common benign homograph that would
 * break the high-precision boundary: `spic` (spic and span), `coon`
 * (raccoon, cheese brand), `dyke` (dike), `chink` (a chink in armor), `beaner`
 * (a bean seller), and any term that is also an ordinary food or place name.
 * `faggot(s)` is also a food name, so it is handled by `CONTEXTUAL_TERM`
 * instead of being listed here.
 */
const IDENTITY_TERMS: ReadonlyArray<{ term: string; suffix?: string }> = [
  { term: "nigger", suffix: "[sz]*" },
  { term: "nigga", suffix: "[sz]*" },
  { term: "fag", suffix: "s*" },
  { term: "kike", suffix: "s*" },
  { term: "wetback", suffix: "s*" },
  { term: "towelhead", suffix: "s*" },
  { term: "raghead", suffix: "s*" },
  { term: "gook", suffix: "s*" },
  { term: "paki", suffix: "s*" },
  { term: "tranny" },
  { term: "trannies" },
  { term: "retard", suffix: "(?:e+d+)?s*" },
  // A directed self-harm abbreviation rather than an identity slur, but it is
  // a single unambiguous token with no benign use between participants.
  { term: "kys" },
];

function compileTerm(term: string, suffix = ""): string {
  const runs = term.match(/(.)\1*/g) ?? [];
  const body = runs
    .map((run) => (run.length === 1 ? `${run}+` : `${run[0]}{${run.length},}`))
    .join("");
  return `${body}${suffix}`;
}

const IDENTITY_TERM_PATTERN = new RegExp(
  `^(?:${IDENTITY_TERMS.map(({ term, suffix }) => compileTerm(term, suffix)).join("|")})$`
);

/**
 * A term that is also an ordinary food name (`faggots`, a British dish), so it
 * is not an unconditional identity term. It is refused only through the
 * second-person rule in `PHRASE_RULES`, which is what establishes that it is
 * aimed at a participant.
 */
const CONTEXTUAL_TERM = compileTerm("faggot", "s*");

/**
 * Plain spellings a masked unit may be restored to. Terms of three letters or
 * fewer (`fag`, `kys`) are absent on purpose: masking one leaves too little
 * visible to call it obvious. Every entry is matched letter for letter, so
 * there is no inflection or repeat tolerance here.
 */
const MASKABLE_FORMS: readonly string[] = [
  "nigger", "niggers", "nigga", "niggas",
  "faggot", "faggots",
  "kike", "kikes",
  "wetback", "wetbacks",
  "towelhead", "towelheads",
  "raghead", "ragheads",
  "gook", "gooks",
  "paki", "pakis",
  "tranny", "trannies",
  "retard", "retards", "retarded",
];

/** Censor characters, each read as exactly one hidden letter. */
const MASK_CHARACTERS = "*#_";
const MASK_PRESENT = /[*#_]/;
const MAX_MASKS = 2;
const MIN_VISIBLE_LETTERS = 3;
/** Longer chunks cannot be a masked term plus ordinary edge punctuation. */
const MAX_MASKED_CHUNK = 64;
/**
 * Edge punctuation (which includes leading or trailing censor characters,
 * markdown emphasis, bullets, and footnote asterisks) is peeled off; the core
 * must be letters, digits, and censor characters only, so a unit with any other
 * interior punctuation is never treated as masked. One conventional trailing
 * English possessive (`'s`, ASCII or typographic apostrophe) may follow the
 * core, and only there: `n*gger's` restores while `n*g'ger` and `n*gger'x` do
 * not. A trailing plural possessive (`n*ggers'`) is already edge punctuation.
 */
const MASKED_UNIT = /^([^a-z0-9]*)([a-z0-9][a-z0-9*#_]*[a-z0-9])((?:['’]s)?[^a-z0-9]*)$/u;

function restoreMaskedForm(core: string): string | null {
  let masks = 0;
  for (const character of core) {
    if (MASK_CHARACTERS.includes(character)) masks += 1;
  }
  if (masks === 0 || masks > MAX_MASKS || core.length - masks < MIN_VISIBLE_LETTERS) {
    return null;
  }
  for (const form of MASKABLE_FORMS) {
    if (form.length !== core.length) continue;
    let matches = true;
    for (let index = 0; index < form.length; index += 1) {
      const character = core[index];
      if (character !== form[index] && !MASK_CHARACTERS.includes(character)) {
        matches = false;
        break;
      }
    }
    if (matches) return form;
  }
  return null;
}

/**
 * Replaces each masked unit that restores to a maskable term with the term's
 * plain spelling, so the whole-unit and phrase rules judge it exactly as they
 * would the unmasked word. Whitespace and every other unit are unchanged.
 */
function restoreMaskedUnits(variant: string): string {
  if (!MASK_PRESENT.test(variant)) return variant;
  return variant.replace(/\S+/gu, (chunk) => {
    if (chunk.length > MAX_MASKED_CHUNK || !MASK_PRESENT.test(chunk)) return chunk;
    const parts = MASKED_UNIT.exec(chunk);
    if (!parts) return chunk;
    const form = restoreMaskedForm(parts[2]);
    return form === null ? chunk : `${parts[1]}${form}${parts[3]}`;
  });
}

/** Longest spelled-out window tested inside a run of single letters: the
 * longest term is nine letters, and this leaves room for repeated letters. */
const MAX_SPELLED_WINDOW = 24;

/**
 * Whether `variant` contains an identity slur, matched only as a WHOLE unit:
 * every alphanumeric token; every whitespace-delimited chunk with punctuation
 * squashed out; and every contiguous window of a run of three or more
 * single-character chunks (a chunk that is only punctuation is transparent, so
 * `k . y . s` is one run). Windows, not just the whole run, so a leading
 * single-letter word (`a n i g g e r`) cannot hide the term behind it. Windows
 * are bounded by `MAX_SPELLED_WINDOW`, so the work stays linear in the input.
 */
function containsIdentitySlur(variant: string): boolean {
  let singles: string[] = [];
  const spelledRunMatches = (): boolean => {
    const run = singles;
    singles = [];
    for (let start = 0; start + 3 <= run.length; start += 1) {
      let joined = "";
      for (
        let end = start;
        end < run.length && joined.length < MAX_SPELLED_WINDOW;
        end += 1
      ) {
        joined += run[end];
        if (end - start >= 2 && IDENTITY_TERM_PATTERN.test(joined)) return true;
      }
    }
    return false;
  };

  for (const chunk of variant.split(/\s+/u)) {
    if (chunk === "") continue;
    for (const token of chunk.match(ALNUM_TOKEN) ?? []) {
      if (IDENTITY_TERM_PATTERN.test(token)) return true;
    }
    const squashed = chunk.replace(NON_ALNUM, "");
    if (squashed === "") continue;
    if (squashed !== chunk && IDENTITY_TERM_PATTERN.test(squashed)) return true;
    if (squashed.length === 1) {
      singles.push(squashed);
    } else if (spelledRunMatches()) {
      return true;
    }
  }
  return spelledRunMatches();
}

// Second-person and first-person building blocks. Tokens are split on every
// non-alphanumeric, so `you're` is `you re` and `I'll` is `i ll`.
const YOU = "(?:you|u|ur|youre)";
const OBJECT_YOU = "(?:you|u)";
const YOURSELF = "(?:yourself|urself|yourselves)";
const COPULA = "(?:are|re|r|is|s)";
const SUBJECT = "(?:i|im|ill|imma|ima|we|well)";
const INTENT = "(?: (?:ll|m|will|am|gonna|going|to|gon|na|finna|about|bout|just|really|swear|promise|definitely|d)){0,4}";
const WANTING = "(?: (?:ll|m|will|am|gonna|going|to|gon|na|finna|about|bout|just|really|want|wanna|would|d|love|like|need|gotta|have)){0,5}";

const ABUSE_NOUN =
  "(?:bitch|bitches|cunt|cunts|whore|whores|slut|sluts|skank|skanks|fucker|fuckers|motherfucker|motherfuckers|asshole|assholes|dickhead|dickheads|scumbag|scumbags)";
const ABUSE_FILLER =
  "(?:a|an|the|such|so|fucking|fuckin|stupid|dumb|ugly|fat|worthless|disgusting|pathetic|little|dirty|filthy|useless|dumbass)";
// `you` after a giving or serving verb is an ordinary indirect object
// (`thank you faggots and peas`, `I'll bring you faggots`, `I ordered you
// faggots`), not a target.
const INDIRECT_OBJECT_VERB =
  "(?:thank|thanks|give|gave|bring|brought|get|got|make|made|buy|bought|send|sent|cook|cooked|serve|served|grab|fetch|order|ordered|ordering|owe|show|pass|save)";
const THREAT_VERB = "(?:kill|murder|stab|strangle|choke|hurt|punch|assault)";
const SEXUAL_VERB = "(?:fuck|rape|molest|grope)";
const PROFANE_VERB = "(?:fuck|fck|fuk)";
const RELATION_NOUN = "(?:mom|mother|mama|face|life|family)";
/**
 * The second-person frame that makes the food-name term (and an otherwise
 * culinary `retard`) participant-directed: `you`, `u`, or `youre` with an
 * optional copula, determiner, or abusive adjective. `ur` is ambiguous
 * (`you're` or the possessive `your`, as in `heat ur fat faggots`), so on its
 * own it is not targeting evidence; it counts only in the predicate frame
 * `ur a ...` / `ur such a ...`, which a possessive cannot form.
 */
const SECOND_PERSON_FRAME = `(?:(?:you|u|youre)(?: ${COPULA})?(?: ${ABUSE_FILLER}){0,3}|ur(?: such)? (?:a|an)(?: ${ABUSE_FILLER}){0,2})`;

interface PhraseRule {
  category: Exclude<ParticipantTextCategory, "identity-slur">;
  /** Matched against ` ${tokens.join(" ")} `, so each rule starts and ends on a token boundary. */
  pattern: RegExp;
}

/**
 * Evaluated in order, so a phrase that fits two families reports the more
 * specific one (e.g. `I want to fuck you` is sexual abuse, not merely
 * `fuck you`).
 */
const PHRASE_RULES: readonly PhraseRule[] = [
  // Threats: first-person violent intent aimed at a second person.
  { category: "threat", pattern: new RegExp(` ${SUBJECT}${INTENT} ${THREAT_VERB} ${OBJECT_YOU} `) },
  {
    category: "threat",
    pattern: new RegExp(
      ` ${SUBJECT}${INTENT} (?:beat|kick) (?:you (?:up|down)|your ass|the (?:shit|crap|hell) out of you) `
    ),
  },
  {
    category: "threat",
    pattern: new RegExp(
      ` ${SUBJECT}${INTENT} shoot you (?:dead|up|in the (?:head|face|back|leg|chest)) `
    ),
  },
  {
    category: "threat",
    pattern: new RegExp(` i know where ${OBJECT_YOU} (?:live|lives|sleep|work|stay|study|reside) `),
  },

  // Severe sexual language aimed at a second person.
  { category: "sexual-abuse", pattern: new RegExp(` (?:suck|lick) my (?:dick|cock|balls|pussy|ass|tits|nuts) `) },
  {
    category: "sexual-abuse",
    pattern: new RegExp(
      ` (?:send|show|give|gimme)(?: me)?(?: (?:your|ur|some))? (?:nudes?|nude pics?|nude photos?|tits|titties|boobs|pussy|dick) `
    ),
  },
  { category: "sexual-abuse", pattern: new RegExp(` ${SUBJECT}${WANTING} ${SEXUAL_VERB} ${OBJECT_YOU} `) },
  { category: "sexual-abuse", pattern: new RegExp(` (?:let me|lemme) (?:fuck|rape|grope) ${OBJECT_YOU} `) },

  // Targeted abuse: abusive language with a second-person target.
  {
    category: "targeted-abuse",
    pattern: new RegExp(` ${YOU}(?: ${COPULA})?(?: ${ABUSE_FILLER}){0,3} ${ABUSE_NOUN} `),
  },
  {
    category: "targeted-abuse",
    pattern: new RegExp(` ${YOU}(?: ${COPULA})?(?: ${ABUSE_FILLER}){0,3} piece of (?:shit|crap|garbage|trash) `),
  },
  // The food-name term (`CONTEXTUAL_TERM`) is judged by
  // `matchesPunctuationAwareRules`, because its indirect-object exclusion
  // depends on punctuation this token stream no longer carries.
  // `ya` is deliberately absent here: `fuck ya, pizza time` is an exclamation
  // (`fuck yeah`), and `ya` alone does not establish a target. It still counts
  // beside a relation noun (`fuck ya mom`), which only a target can take — see
  // `matchesPunctuationAwareRules`, since that reading needs no punctuation
  // between `ya` and the noun.
  { category: "targeted-abuse", pattern: new RegExp(` (?:fuck|fck|fuk) (?:you|u|yourself|urself|off) `) },
  {
    category: "targeted-abuse",
    pattern: new RegExp(` ${PROFANE_VERB} (?:your|ur) ${RELATION_NOUN} `),
  },
  // `don't kill yourself over this` is an ordinary idiom, not abuse.
  {
    category: "targeted-abuse",
    pattern: new RegExp(
      `(?<! (?:don t|dont|never|not|wont|won t)) (?:kill|hang|choke|drown) ${YOURSELF} `
    ),
  },
  {
    category: "targeted-abuse",
    pattern: new RegExp(
      ` (?:i )?hope ${OBJECT_YOU} (?:die|dies|get (?:cancer|raped|killed|stabbed)) `
    ),
  },
  {
    category: "targeted-abuse",
    pattern: new RegExp(` ${OBJECT_YOU} (?:should|deserve to|ought to|need to|must) (?:die|be killed|be raped) `),
  },
];

/**
 * `retard`, `retards`, and `retarded` are also the culinary verb for slowing
 * dough fermentation in the cold (`cold retarded pizza dough`, `retard the
 * dough overnight`). A plain token of that family within `CULINARY_WINDOW`
 * tokens of one of these dough/fermentation words is that culinary verb, so it
 * is neutralized before any rule runs. Everything else is unchanged: the bare
 * term, `you're a retard`, `a retard at the counter`, and every masked,
 * spaced-out, or punctuation-squashed spelling (restored or matched later, and
 * never reached here) stay refused. This is a single-homograph guard, not a
 * food vocabulary, and it never overrides an already-clear second-person
 * frame: a token preceded by a copula or an adjective/determiner aimed at
 * `you` (`you're a retard`, `you are retarded`, `u r retarded`, `you stupid
 * retard`, `ur a retard`) is never the culinary verb, whatever is nearby. A bare
 * `you retard` beside a dough word stays culinary, because that is exactly the
 * verb's own second-person use (`if you retard the dough`); that collision is a
 * documented limitation.
 */
const CULINARY_RETARD_TOKEN = /^retard(?:ed|s)?$/;
const CULINARY_RETARD_CONTEXT: ReadonlySet<string> = new Set([
  "dough", "doughs", "sourdough", "proof", "proofed", "proofing",
  "ferment", "fermented", "fermenting", "fermentation", "yeast",
]);
const CULINARY_WINDOW = 3;
/**
 * `SECOND_PERSON_FRAME` minus bare `you`/`u`: at least a copula or one
 * adjective/determiner must separate them from the token, which the culinary
 * verb never takes. Anchored at the end of the preceding tokens.
 */
const RETARD_TARGET_FRAME = new RegExp(
  `(?:^| )(?:(?:you|u)(?: ${COPULA}(?: ${ABUSE_FILLER}){0,3}|(?: ${ABUSE_FILLER}){1,3})|youre(?: ${COPULA})?(?: ${ABUSE_FILLER}){0,3}|ur(?: such)? (?:a|an)(?: ${ABUSE_FILLER}){0,2})$`
);
/** The longest `RETARD_TARGET_FRAME` is `you` + copula + three fillers. */
const RETARD_TARGET_LOOKBACK = 5;

function inSecondPersonTargetFrame(tokens: readonly string[], index: number): boolean {
  const preceding = tokens.slice(Math.max(0, index - RETARD_TARGET_LOOKBACK), index);
  return RETARD_TARGET_FRAME.test(preceding.join(" "));
}

/**
 * Runs on the folded text only, before leet substitution, so only a plainly
 * spelled token can ever be read as the culinary verb: `r3tard dough` is
 * judged by the leet variant as the slur, never neutralized there.
 */
function neutralizeCulinaryRetard(variant: string): string {
  if (!variant.includes("retard")) return variant;
  const tokens = variant.match(ALNUM_TOKEN);
  if (!tokens) return variant;
  const culinary = new Set<number>();
  tokens.forEach((token, index) => {
    if (!CULINARY_RETARD_TOKEN.test(token)) return;
    if (inSecondPersonTargetFrame(tokens, index)) return;
    const last = Math.min(tokens.length - 1, index + CULINARY_WINDOW);
    for (let near = Math.max(0, index - CULINARY_WINDOW); near <= last; near += 1) {
      if (CULINARY_RETARD_CONTEXT.has(tokens[near])) {
        culinary.add(index);
        return;
      }
    }
  });
  if (culinary.size === 0) return variant;
  let position = 0;
  return variant.replace(ALNUM_TOKEN, (token) => (culinary.has(position++) ? "delay" : token));
}

/**
 * The food-name term in `SECOND_PERSON_FRAME`, tried at one token boundary.
 * Sticky, and its `lastIndex` is assigned immediately before every use, so no
 * state carries from one evaluation to the next.
 */
const CONTEXTUAL_TARGET = new RegExp(` ${SECOND_PERSON_FRAME} ${CONTEXTUAL_TERM} `, "y");
const CONTEXTUAL_TARGET_START: ReadonlySet<string> = new Set(["you", "u", "youre", "ur"]);
const INDIRECT_OBJECT_VERB_TOKEN = new RegExp(`^${INDIRECT_OBJECT_VERB}$`);
const PROFANE_VERB_TOKEN = new RegExp(`^${PROFANE_VERB}$`);
const RELATION_NOUN_TOKEN = new RegExp(`^${RELATION_NOUN}$`);
const WHITESPACE_ONLY = /^\s+$/u;

/**
 * The two targeted-abuse rules whose reading depends on punctuation that the
 * space-joined token stream discards. `whitespaceBefore[i]` says whether token
 * `i` is separated from token `i - 1` by whitespace alone.
 *
 * - The food-name term in a second-person frame, except where that `you` is
 *   the indirect object of a giving, serving, or ordering verb right before it
 *   (`I ordered you faggots`). Punctuation between the verb and `you` breaks
 *   that reading, so `Ordered, you faggot` is a vocative and stays refused.
 * - `fuck ya` + relation noun, only when `ya` and the noun are joined by
 *   whitespace alone (`fuck ya mom`). `Fuck ya! Family bucket` is an
 *   exclamation followed by an order, not a target.
 */
function matchesPunctuationAwareRules(
  tokens: readonly string[],
  whitespaceBefore: readonly boolean[],
  phrase: string
): boolean {
  // `phrase` is ` ${tokens.join(" ")} `, so token `i` starts at `offset`
  // and the boundary space before it is at `offset - 1`.
  let offset = 1;
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (CONTEXTUAL_TARGET_START.has(token)) {
      CONTEXTUAL_TARGET.lastIndex = offset - 1;
      if (CONTEXTUAL_TARGET.test(phrase)) {
        const isIndirectObject =
          index > 0 &&
          whitespaceBefore[index] &&
          INDIRECT_OBJECT_VERB_TOKEN.test(tokens[index - 1]);
        if (!isIndirectObject) return true;
      }
    }
    if (
      token === "ya" &&
      index > 0 &&
      index + 1 < tokens.length &&
      PROFANE_VERB_TOKEN.test(tokens[index - 1]) &&
      RELATION_NOUN_TOKEN.test(tokens[index + 1]) &&
      whitespaceBefore[index + 1]
    ) {
      return true;
    }
    offset += token.length + 1;
  }
  return false;
}

function categorizeVariant(rawVariant: string): ParticipantTextCategory | null {
  // Masked units are restored after culinary neutralization (which already ran
  // on the folded text), so a masked `r*tard` beside a dough word stays refused.
  const variant = restoreMaskedUnits(rawVariant);
  if (containsIdentitySlur(variant)) {
    return "identity-slur";
  }
  const tokens: string[] = [];
  const whitespaceBefore: boolean[] = [];
  let previousEnd = 0;
  for (const match of variant.matchAll(ALNUM_TOKEN)) {
    const start = match.index ?? 0;
    whitespaceBefore.push(WHITESPACE_ONLY.test(variant.slice(previousEnd, start)));
    tokens.push(match[0]);
    previousEnd = start + match[0].length;
  }
  if (tokens.length === 0) return null;
  const phrase = ` ${tokens.join(" ")} `;
  for (const { category, pattern } of PHRASE_RULES) {
    if (pattern.test(phrase)) return category;
  }
  // Every rule in here is targeted abuse, and every phrase rule that could
  // also match is either targeted abuse or a more specific category tried
  // above, so checking these last reports the same category as before.
  if (matchesPunctuationAwareRules(tokens, whitespaceBefore, phrase)) {
    return "targeted-abuse";
  }
  return null;
}

/**
 * Evaluates one participant-authored string. Pure, deterministic, and
 * side-effect free: no I/O, no logging, no module state.
 */
export function evaluateParticipantText(text: string): ParticipantTextVerdict {
  // Culinary neutralization runs once, on the folded text, and the leet
  // variant is derived from its result: only a plainly spelled `retard` beside
  // a dough word can be the culinary verb, never one leet substitution made.
  const neutralized = neutralizeCulinaryRetard(fold(text));
  const category =
    categorizeVariant(neutralized) ?? categorizeVariant(applyLeet(neutralized));
  return category ? { allowed: false, category } : { allowed: true };
}

export function isParticipantTextAllowed(text: string): boolean {
  return evaluateParticipantText(text).allowed;
}
