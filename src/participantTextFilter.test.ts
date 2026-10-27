import { describe, expect, it } from "vitest";
import {
  evaluateParticipantText,
  isParticipantTextAllowed,
} from "./participantTextFilter.js";

/**
 * W4-U1.1 focused corpus for the provider-free participant-text filter.
 *
 * Two corpora define the accepted precision boundary. The ACCEPTED corpus is
 * ordinary food/order/helper text that must never be refused — including
 * legitimate-context profanity, slang, unusual food names, links, phone
 * numbers, emails, and unfamiliar vocabulary. The BLOCKED corpus is the narrow
 * high-confidence set the READY contract names. This is not a general
 * profanity filter, so a test here that tries to make it one is a regression.
 */

const ACCEPTED_ORDER_TEXT = [
  // Ordinary requests.
  "Chicken Wings",
  "Spicy chicken sandwich, no pickles",
  "2 orders of fries and a large Coke",
  "Pad thai (extra spicy), no peanuts",
  "Turkey club on wheat, light mayo",
  "A1 sauce on the side please",
  "7UP and a side of 5 onion rings",
  "Large iced coffee with oat milk, 3 pumps vanilla",
  // Unusual / unfamiliar food names and vocabulary.
  "Bánh mì with extra jalapeños",
  "Crème brûlée latte",
  "Açaí bowl",
  "Xiao long bao x6",
  "Shakshuka with labneh",
  "Pasta e fagioli",
  "Nigerian jollof rice",
  "Niger seed flatbread",
  "Snickerdoodle cookie",
  "Kikkoman soy sauce packets",
  "Cocktail shrimp",
  "Classic assassin burger",
  "Dickey's BBQ pulled pork",
  "Penne alla vodka",
  "Scunthorpe pork pie",
  "Spic and span clean fork please",
  "Ñoquis con salsa",
  "寿司 roll and miso soup",
  "кофе latte",
  // Real menu / brand names that contain edgy words as part of a longer word.
  "Slutty Vegan One Night Stand burger",
  "Bitchin' Sauce on the side",
  "Dirty chai",
  "Naked burrito bowl",
  "Sex on the Beach smoothie",
  "Hell fire wings",
  // Ordinary profanity in a legitimate food/order context is NOT refused.
  "This burger is fucking amazing",
  "Shit, make it extra spicy",
  "Extra fucking cheese please",
  "Damn good fries, hell yeah",
  "Kick-ass hot sauce on everything",
  "That wait was bullshit but the food slaps",
  // Slang.
  "no cap that was bussin fr fr",
  "lowkey starving rn",
  "ngl I'm cooked, just get me a sandwich",
  "bruh the line was insane",
  // Links, phone numbers, emails.
  "https://www.grubhub.com/restaurant/some-spot/123456",
  "menu at example.com/menu?item=chicken-wings&size=large",
  "text me at 917-555-0142 or (212) 555-0199",
  "reach me at student1234@nyu.edu",
  // Helper Message style text.
  "Hi! I placed the order, I'll shoot you a text when I'm outside.",
  "I'll find you at the entrance.",
  "Thanks so much for helping, I'll meet you at Weinstein at 6.",
  "You're the best, thank you!",
  "I'll beat you to the dining hall",
  "You can't beat that price",
  "I could kill for a burger right now",
  "This sauce will kill you in a good way",
  "You're gonna die when you taste this",
  "I know where you left your bag",
  "I know where you sit at lunch",
  "I'd love to buy you a coffee",
  "I want to fuck up my diet with this sandwich",
  "I wanna thank you so much",
  "I hope you enjoy the fries",
  "Go ok then, I'll take the wings",
  "go die for the last slice lol",
  // Idioms that share words with threats/abuse but have no second-person target.
  "I will kill your hunger with this sandwich",
  "Don't kill yourself carrying all those bags",
  "shoot yourself a snack while you wait",
  "I'll hurt for sleep tonight lol",
];

const BLOCKED_IDENTITY_SLURS = [
  "nigger",
  "NIGGER",
  "NiGgEr",
  "Nigger!!!",
  "niggers",
  "nigga",
  "niggas",
  "fag",
  "fags",
  "kike",
  "wetback",
  "towelhead",
  "raghead",
  "gook",
  "paki",
  "tranny",
  "retard",
  "retarded",
  "kys",
  // Embedded in an otherwise ordinary sentence.
  "Extra napkins please, you nigger",
  "tell that fag thanks for the food",
  "the guy at the counter was a retard",
];

/** Obvious normalization / obfuscation variants of the same terms. */
const BLOCKED_NORMALIZED_VARIANTS = [
  // Leet-style digit/symbol substitution.
  "n1gger",
  "n!gger",
  "nigg3r",
  "n1gg3r",
  "f4g",
  "k1k3",
  "r3tard",
  "w3tback",
  // Repeated letters.
  "niggerrrr",
  "niiiigger",
  "faaaag",
  // Case and compatibility forms.
  "ｎｉｇｇｅｒ", // fullwidth
  "𝐧𝐢𝐠𝐠𝐞𝐫", // mathematical bold
  "ⓝⓘⓖⓖⓔⓡ", // circled
  // Diacritics.
  "nîgger",
  "fàg",
  // Zero-width / invisible / soft-hyphen insertion.
  "ni​gger",
  "n‍ig‌ger",
  "ni­gger",
  "nig﻿ger",
  "ni⁠gger",
  // Cyrillic / Greek lookalikes.
  "nіgger", // Cyrillic і
  "nιgger", // Greek ι
  "kіkе", // Cyrillic і, е
  "fаg", // Cyrillic а
  // Separator insertion within one chunk.
  "nig-ger",
  "nig.ger",
  "nig_ger",
  "n.i.g.g.e.r",
  "n-i-g-g-e-r",
  "n_i_g_g_e_r",
  // Spaced single letters.
  "n i g g e r",
  "f a g",
  "k y s",
  "K.Y.S.",
  "k . y . s",
  // Latin small capitals.
  "ɴɪɢɢᴇʀ",
  "ꜰᴀɢ",
  // Uppercase spaced run with a plural.
  "N I G G E R S",
  // A leading single-letter word must not hide a spaced-out term: the run is
  // `a n i g g e r`, and the term is any bounded window inside it.
  "a n i g g e r",
  "I k y s",
  "so f a g s lol",
  // Combined.
  "N.1.G.G.3.R",
];

const BLOCKED_TARGETED_ABUSE = [
  "you stupid bitch",
  "you are a worthless cunt",
  "ur a whore",
  "you're a fucking slut",
  "you are such a dirty skank",
  "you motherfucker",
  "fuck you",
  "FUCK U",
  "fuck off",
  "go fuck yourself",
  "kill yourself",
  "go kill yourself",
  // Clear second-person targeting is unchanged by the `ya` correction.
  "fuck you, pizza time",
  "FUCK YOU ya dirty",
  "fuck ya mom",
  "fuck ya mama",
  "fuck ya family",
  "fuck ya life",
  "fck ya mom",
  // Whitespace alone (any amount) still joins `ya` to the relation noun.
  "fuck ya  mom",
  "fuck ya\nmom",
  "fuck ur mom",
  // `your`/`ur` are unchanged: punctuation does not affect them.
  "fuck your mom",
  "fuck your family",
  "you piece of shit",
  "you're a piece of shit",
  "I hope you die",
  "i hope u die",
  "you deserve to die",
  "you should die",
  "u should kill yourself",
];

const BLOCKED_THREATS = [
  "I will kill you",
  "I'll kill you",
  "i'm going to murder you",
  "im gonna kill you",
  "imma stab you",
  "I swear to god I will kill you",
  "I'm going to beat you up",
  "I'll kick your ass",
  "I'll beat the shit out of you",
  "I will shoot you dead",
  "I will strangle you",
  "i know where you live",
  "I know where u live",
  "I know where you sleep",
  "we will hurt you",
  "I'll shoot you in the head",
  // Leet-style substitution reaches the phrase rules too.
  "i w1ll k1ll y0u",
];

const BLOCKED_SEVERE_SEXUAL = [
  "I want to fuck you",
  "I will rape you",
  "imma rape you",
  "let me fuck you",
  "suck my dick",
  "send me nudes",
  "send nudes",
  "show me your tits",
];

/**
 * `faggots` is a traditional British dish, so the token is an ambiguous food
 * name: it is never refused on its own, in any inflection or spelling, and is
 * refused only when a second-person target makes the participant-directed
 * meaning clear. Neighbouring substrings and homographs must also pass.
 */
const ACCEPTED_FOOD_HOMOGRAPH_TEXT = [
  "faggots",
  "Faggots",
  "FAGGOTS",
  "faggot",
  "Faggots and peas",
  "Pork faggots with onion gravy",
  "Two faggots, mash and mushy peas",
  "2 faggots please",
  "Mrs Miggins' faggots in gravy",
  "I'd like the faggots and chips",
  "Can you get faggots and peas?",
  "Do you have faggots?",
  "Faggots for you and a friend",
  // `you` as the indirect object of a giving or serving verb is not a target.
  "Thank you, faggots and peas please",
  "thank you faggots and mash",
  "I'll bring you faggots and peas",
  "I got you faggots with gravy",
  "I made you a faggot sandwich",
  // `order` is the same indirect-object verb in this domain.
  "I ordered you faggots and peas",
  "I'll order you faggots",
  "I'll order you faggots and mash",
  "ordering you faggots",
  "ordered you faggots",
  "Just ordered you a faggot sandwich",
  // `ur` is ambiguous with the possessive `your`, so it is not targeting
  // evidence on its own, with or without an adjective before the dish.
  "ur faggots",
  "heat ur faggots",
  "heat ur faggots and peas",
  "heat ur fat faggots",
  "pick ur little faggots",
  "pick up ur dirty faggots",
  "ur dirty faggots",
  "ur ugly faggots please",
  "Can you heat ur faggots?",
  // Spelling variants of the dish name are no more targeted than the plain one.
  "f4ggots and peas",
  "f*ggots and peas",
  // Nearby substrings and homographs.
  "Fagottini with ricotta",
  "Pasta e fagioli",
  "Fagioli beans",
  "Faggoting is a woodworking term",
];

const BLOCKED_MASKED_SLURS = [
  "n*gger",
  "N*GGER",
  "n*ggers",
  "n*gga",
  "n*ggas",
  "n#gger",
  "n_gger",
  "ni*ger",
  "nig*er",
  "nigg*r",
  "n**ger",
  "n*gg*r",
  "ni**a",
  "k*ke",
  "k*kes",
  "p*ki",
  "g*ok",
  "w*tback",
  "tow*lhead",
  "ragh*ad",
  "tr*nny",
  "tr*nnies",
  "r*tard",
  "ret*rded",
  // Edge punctuation, quoting, and emphasis around a masked unit.
  "\"n*gger\"",
  "n*gger!",
  "(n*gger)",
  "**n*gger**",
  "n*gger.",
  // A conventional trailing possessive does not defeat a masked term.
  "n*gger's",
  "n*gger’s",
  "N*GGER'S",
  "n*ggers'",
  "n**ger's",
  "r*tard's",
  "(n*gger's)",
  "n*gger's.",
  "you n*gger's",
  // In a sentence.
  "Extra napkins please, you n*gger",
  "the guy at the counter was a r*tard",
  // Mask combined with another normalization.
  "n*gg3r",
  "n*gg3rs",
  "ｎ*ｇｇｅｒ",
];

/** A second-person target is what makes the ambiguous food-name term abusive. */
const BLOCKED_TARGETED_FOOD_HOMOGRAPH = [
  "you faggot",
  "you faggots",
  "You Faggot!",
  "you're a faggot",
  "you are a faggot",
  "you are faggots",
  "u r a faggot",
  "ur a faggot",
  "ur an faggot",
  "ur such a faggot",
  "ur a dirty faggot",
  "ur such a fucking faggot",
  "youre a faggot",
  "youre faggots",
  "u faggot",
  "you stupid faggot",
  "you fucking faggots",
  "you're such a dirty faggot",
  "are you a faggot",
  "Extra napkins please, you faggot",
  // The indirect-object exclusion is only for `you` right after the verb.
  "I ordered fries, you faggot",
  "you faggot, I ordered fries",
  "order up, you faggot",
  "I ordered it and you're a faggot",
  // ...and only when the verb and `you` are separated by whitespace alone:
  // punctuation between them makes `you` a vocative, not an indirect object.
  "Ordered, you faggot",
  "I'll order, you faggots",
  "ordered. you faggot",
  "Thanks, you faggot",
  "thanks! you faggot",
  "I brought it, got it? you faggot",
  "made - you stupid faggot",
  // Normalized spellings are judged exactly like the plain word.
  "you f4ggot",
  "you faaaaggot",
  "you fàggot",
  "you fаggot", // Cyrillic а
  "you ꜰᴀɢɢᴏᴛ", // small capitals
  "you ｆａｇｇｏｔ", // fullwidth
  "you f*ggot",
  "you're a f*ggot",
  "you f\u200baggot", // zero-width space
];

/**
 * Words and shapes that sit next to a masked term but are not one: a real
 * word one letter off, ordinary punctuation, markup, and footnote marks.
 */
const ACCEPTED_MASK_AND_PUNCTUATION_TEXT = [
  // One letter off a term, so the mask restores to nothing.
  "n*gget",
  "Chicken n*ggets",
  "n*gge",
  "n*ger",
  "s*igger",
  "p*ke",
  // Too little visible: three-letter terms and two-mask short terms.
  "k*s",
  "f*g",
  "g**k",
  "k**e",
  // Three or more masks, or masks at the edge of a unit.
  "n***er",
  "n*g*e*",
  "*igger",
  "nigge*",
  // Ordinary punctuation-bearing food and order text.
  "Mac*n*Cheese",
  "M*A*S*H",
  "5* rating",
  "**Extra spicy**",
  "*note: no onions",
  "burger* (see note)",
  "snake_case_order_name",
  "order#12 for pickup",
  "Ben & Jerry's",
  "P.F. Chang's",
  "Dunkin' Donuts",
  "S'mores",
  "half-and-half",
  "rice/beans",
  "no. 5 combo",
  "Mac & Cheese",
  "a.m. coffee",
  "n'gger",
  "pad-thai",
  "Pick-up @ 6pm",
  // A possessive only helps an otherwise exact masked term: apostrophes
  // anywhere else, or after a non-term, change nothing.
  "n*gget's",
  "n*gget’s",
  "n*g'ger",
  "n*gg'er",
  "n*gger'x",
  "n*gger's's",
  "n*g'sger",
  "*igger's",
  "k*s's",
  "Wendy's",
  "Dunkin’s",
  "Mac*n*Cheese's",
  "chef's special",
  "Papa John's",
];

/**
 * `retard`, `retards`, and `retarded` are also the baking verb for slowing dough
 * fermentation. A plain token of that family within three tokens of a
 * dough/fermentation word is the culinary verb and passes.
 */
const ACCEPTED_CULINARY_RETARD_TEXT = [
  "cold retarded pizza dough",
  "Cold-retarded pizza dough, extra crispy",
  "Retarded sourdough please",
  "retard the dough overnight",
  "I retard my dough in the fridge",
  "if you retard the dough",
  // Bare `you` + the verb is the verb's own second-person use.
  "you retard the dough overnight",
  "Can you retard the dough for 48 hours?",
  "dough retarded 24 hours",
  "pizza dough that was retarded for two days",
  "bulk fermentation retarded overnight",
  "retard your bulk fermentation",
  "this retards fermentation",
  "cold retards the proofing",
  "yeast retarded by the cold",
  "RETARDED DOUGH",
  // Neighbouring words that are not the family at all.
  "retarding the dough",
  "retardant",
  "retardation of the proof",
];

/** The slur stays refused: bare, targeted, third-party, or out of the dough window. */
const BLOCKED_RETARD_SLUR_TEXT = [
  "retard",
  "retarded",
  "retards",
  "RETARD",
  "you retard",
  "you're a retard",
  "you are retarded",
  "u r retarded",
  "what a retard",
  "that guy is a retard",
  "the retard at the counter forgot my dough",
  "you retard, anyway can I get extra dough and sauce",
  "this is retarded, where is my food",
  "the dough guy was a retard",
  // A masked, spaced, or leet spelling is never a culinary token.
  "r*tard dough",
  "ret*rded sourdough",
  "r3tard",
  "r e t a r d",
  "re-tard",
  // Leet substitution happens after culinary neutralization, so a leet slur
  // beside a dough word is never read as the culinary verb.
  "r3tard dough",
  "r3t4rd3d dough",
  "R3TARD sourdough",
  // A clear second-person frame is never overridden by a nearby dough or
  // fermentation word (including the ordinary English word `proof`).
  "you're a retard, here's proof",
  "you're retarded, I have proof",
  "you stupid retard dough",
  "ur a retard yeast",
  "you are a fucking retard lol dough",
  "u r retarded sourdough",
  "you're so retarded, nice dough",
  "youre a retard dough",
  "ur such a retard, proof it",
];

/**
 * Documented limitation, not a target: a bare `you retard` beside a dough word
 * is indistinguishable from the verb's own second-person use (`if you retard
 * the dough`), so it keeps the culinary reading.
 */
const DOCUMENTED_BARE_VOCATIVE_RETARD_TEXT = [
  "nice dough, you retard",
  "you retard, proof it",
];

/** `ya` is slang that does not by itself make an exclamation a target. */
const ACCEPTED_YA_TEXT = [
  "Fuck ya, pizza time",
  "fuck ya that was good",
  "Fuck ya!",
  "FUCK YA extra cheese",
  "ya know what, fuck ya, just get me the wings",
  "I'll see ya at the dining hall",
  "thank ya so much",
  // Punctuation between `ya` and a relation noun ends the exclamation: the
  // noun starts the order, it is not `ya`'s object.
  "Fuck ya! Family bucket",
  "Fuck ya, family size pizza please",
  "fuck ya, life saver",
  "Fuck ya, mom's recipe lasagna",
  "fuck ya. mom said order pizza",
  "FUCK YA!! FAMILY MEAL",
];

describe("participant text filter — accepted corpus", () => {
  it.each(ACCEPTED_ORDER_TEXT)("allows %j", (text) => {
    const verdict = evaluateParticipantText(text);
    expect(verdict).toEqual({ allowed: true });
    expect(isParticipantTextAllowed(text)).toBe(true);
  });

  it("allows the empty string and whitespace-only text (presence is validated elsewhere)", () => {
    expect(isParticipantTextAllowed("")).toBe(true);
    expect(isParticipantTextAllowed("   \n\t ")).toBe(true);
  });

  it.each(ACCEPTED_FOOD_HOMOGRAPH_TEXT)("allows the ambiguous food-name term %j", (text) => {
    expect(evaluateParticipantText(text)).toEqual({ allowed: true });
  });

  it.each(ACCEPTED_CULINARY_RETARD_TEXT)("allows the culinary dough-retarding verb %j", (text) => {
    expect(evaluateParticipantText(text)).toEqual({ allowed: true });
  });

  it.each(ACCEPTED_YA_TEXT)("does not read ambiguous `ya` as a target in %j", (text) => {
    expect(evaluateParticipantText(text)).toEqual({ allowed: true });
  });

  it.each(ACCEPTED_MASK_AND_PUNCTUATION_TEXT)(
    "allows ordinary punctuation and near-miss masked text %j",
    (text) => {
      expect(evaluateParticipantText(text)).toEqual({ allowed: true });
    }
  );
});

describe("participant text filter — blocked corpus", () => {
  it.each(BLOCKED_IDENTITY_SLURS)("refuses identity slur / self-harm abuse %j", (text) => {
    const verdict = evaluateParticipantText(text);
    expect(verdict.allowed).toBe(false);
    expect(isParticipantTextAllowed(text)).toBe(false);
  });

  it.each(BLOCKED_NORMALIZED_VARIANTS)("refuses normalized/obfuscated variant %j", (text) => {
    expect(isParticipantTextAllowed(text)).toBe(false);
  });

  it.each(BLOCKED_MASKED_SLURS)("refuses obviously masked identity slur %j", (text) => {
    expect(evaluateParticipantText(text)).toEqual({ allowed: false, category: "identity-slur" });
  });

  it.each(BLOCKED_TARGETED_FOOD_HOMOGRAPH)(
    "refuses the ambiguous food-name term when aimed at a participant %j",
    (text) => {
      expect(evaluateParticipantText(text)).toEqual({ allowed: false, category: "targeted-abuse" });
    }
  );

  it.each(BLOCKED_RETARD_SLUR_TEXT)("refuses the disability slur outside the culinary reading %j", (text) => {
    expect(evaluateParticipantText(text)).toEqual({ allowed: false, category: "identity-slur" });
  });

  it.each(DOCUMENTED_BARE_VOCATIVE_RETARD_TEXT)(
    "documented limitation: bare `you retard` beside a dough word keeps the culinary reading %j",
    (text) => {
      expect(evaluateParticipantText(text)).toEqual({ allowed: true });
    }
  );

  it.each(BLOCKED_TARGETED_ABUSE)("refuses targeted abuse %j", (text) => {
    expect(isParticipantTextAllowed(text)).toBe(false);
  });

  it.each(BLOCKED_THREATS)("refuses clear threat %j", (text) => {
    expect(isParticipantTextAllowed(text)).toBe(false);
  });

  it.each(BLOCKED_SEVERE_SEXUAL)("refuses severe sexual abuse directed at a participant %j", (text) => {
    expect(isParticipantTextAllowed(text)).toBe(false);
  });
});

describe("participant text filter — determinism and containment", () => {
  it("returns the same verdict for the same input every time", () => {
    for (const text of [...ACCEPTED_ORDER_TEXT, ...BLOCKED_THREATS]) {
      const first = evaluateParticipantText(text);
      for (let i = 0; i < 3; i += 1) {
        expect(evaluateParticipantText(text)).toEqual(first);
      }
    }
  });

  it("reports only an opaque category, never the matched text or term", () => {
    const secretText = "Extra napkins please, you nigger";
    const verdict = evaluateParticipantText(secretText);
    expect(verdict.allowed).toBe(false);
    if (verdict.allowed) throw new Error("unreachable");
    expect(Object.keys(verdict).sort()).toEqual(["allowed", "category"]);
    expect(verdict.category).toBe("identity-slur");
    expect(JSON.stringify(verdict)).not.toMatch(/nigger|napkin/i);
  });

  it("classifies each rule family under its own opaque category", () => {
    expect(evaluateParticipantText("kill yourself")).toEqual({
      allowed: false,
      category: "targeted-abuse",
    });
    expect(evaluateParticipantText("I will kill you")).toEqual({
      allowed: false,
      category: "threat",
    });
    expect(evaluateParticipantText("I want to fuck you")).toEqual({
      allowed: false,
      category: "sexual-abuse",
    });
  });

  it("matches terms only as whole units, never as substrings of longer words", () => {
    for (const text of ["snigger", "Snigger", "niger", "Nigeria", "retardant", "fagioli", "kikkoman"]) {
      expect(isParticipantTextAllowed(text)).toBe(true);
    }
  });

  it("does not match a spelled-out run that merely contains letters of a term", () => {
    for (const text of ["a b c d e f g", "i a m s o h u n g r y", "k y", "n i g", "s k y"]) {
      expect(isParticipantTextAllowed(text)).toBe(true);
    }
  });

  it("does not treat a lone edgy noun as abuse without a second-person target", () => {
    for (const text of ["slut", "bitch", "whore", "cunt", "asshole", "slutty", "bitchin"]) {
      expect(isParticipantTextAllowed(text)).toBe(true);
    }
  });

  it("restores every maskable form with any one interior letter masked", () => {
    const forms = [
      "nigger", "niggers", "nigga", "niggas", "kike", "kikes", "wetback", "wetbacks",
      "towelhead", "towelheads", "raghead", "ragheads", "gook", "gooks", "paki", "pakis",
      "tranny", "trannies", "retard", "retards", "retarded",
    ];
    for (const form of forms) {
      for (let index = 1; index < form.length - 1; index += 1) {
        const masked = `${form.slice(0, index)}*${form.slice(index + 1)}`;
        expect(evaluateParticipantText(masked), masked).toEqual({
          allowed: false,
          category: "identity-slur",
        });
      }
    }
    for (const form of ["faggot", "faggots"]) {
      for (let index = 1; index < form.length - 1; index += 1) {
        const masked = `${form.slice(0, index)}*${form.slice(index + 1)}`;
        expect(isParticipantTextAllowed(masked), masked).toBe(true);
        expect(isParticipantTextAllowed(`you ${masked}`), masked).toBe(false);
      }
    }
  });

  it("is deliberately not fuzzy: phonetic and unmasked-profanity forms are out of scope", () => {
    // Documented, accepted non-coverage. Catching these would need phonetic or
    // fuzzy matching, which the READY contract's precision boundary rejects.
    // Masks only restore the identity terms, so masked ordinary profanity
    // (`f**k you`) is also outside this correction.
    for (const text of ["f**k you", "n word", "nigguh", "n1ggah"]) {
      expect(isParticipantTextAllowed(text)).toBe(true);
    }
  });

  it("keeps the ambiguous food-name term allowed on its own and refused only when aimed at a participant", () => {
    // Recorded tradeoff: an untargeted bare `faggot(s)` is no longer refused,
    // because the same token is a legitimate food name. Targeted use is.
    expect(isParticipantTextAllowed("faggots and peas")).toBe(true);
    expect(isParticipantTextAllowed("you faggots")).toBe(false);
    expect(isParticipantTextAllowed("fag")).toBe(false);
  });

  it("stays linear on very large adversarial inputs", () => {
    const repeated = "a ".repeat(50_000);
    const started = Date.now();
    expect(isParticipantTextAllowed(repeated)).toBe(true);
    expect(isParticipantTextAllowed("n".repeat(100_000))).toBe(true);
    expect(isParticipantTextAllowed("you ".repeat(25_000))).toBe(true);
    // Masked-unit restoration is bounded per unit: many masked units, one huge
    // masked unit, and a thank-you indirect-object run must all stay cheap.
    expect(isParticipantTextAllowed("n*gget ".repeat(20_000))).toBe(true);
    expect(isParticipantTextAllowed("a**bcd ".repeat(20_000))).toBe(true);
    expect(isParticipantTextAllowed("n*".repeat(50_000))).toBe(true);
    expect(isParticipantTextAllowed("thank you faggots ".repeat(10_000))).toBe(true);
    // The culinary guard scans a bounded window per token.
    expect(isParticipantTextAllowed("retard dough ".repeat(20_000))).toBe(true);
    expect(isParticipantTextAllowed("retard ".repeat(50_000))).toBe(false);
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  // No wall-clock assertion: these take well under 200 ms alone, and the
  // per-test timeout already fails a superlinear (seconds-to-minutes) blowup
  // without turning machine load during the full suite into a false failure.
  it("keeps the target-frame lookback and punctuation-aware token rules linear", () => {
    expect(isParticipantTextAllowed("you're a retard dough ".repeat(10_000))).toBe(false);
    expect(isParticipantTextAllowed("you are a stupid ".repeat(10_000))).toBe(true);
    expect(isParticipantTextAllowed("ordered, you stupid ".repeat(10_000))).toBe(true);
    expect(isParticipantTextAllowed("fuck ya, ".repeat(10_000))).toBe(true);
  });
});
