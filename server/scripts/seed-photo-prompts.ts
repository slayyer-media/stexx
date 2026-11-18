/**
 * Prints the prompts for the dev-seed profile photos as JSON (one per non-explicit photo slot, max 2 per profile).
 *   bun scripts/seed-photo-prompts.ts > /tmp/specs.json
 *   python scripts/generate-seed-photos.py /tmp/specs.json src/dev/seed-photos
 */
import { buildProfile } from "../src/dev/seed.ts";
const LOOKS = [
  "East Asian", "Black", "white", "South Asian", "Latino", "Middle Eastern", "Southeast Asian", "mixed-race",
  "Pacific Islander", "Indigenous", "Mediterranean", "Nordic", "West African", "Korean", "Brazilian", "Irish",
];
const HAIR = ["short curly hair", "a buzz cut", "wavy hair", "a neat beard", "stubble", "a man bun", "a fade haircut", "long hair tied back", "a mustache", "salt-and-pepper hair", "clean-shaven with short hair", "a full beard"];
const TOPS = ["a denim jacket", "a white t-shirt", "a knit sweater", "a flannel shirt", "a linen shirt", "a hoodie", "a leather jacket", "a button-down shirt", "a tank top", "a rain jacket"];
const SCENES: Record<string, string> = {
  hiking: "on a hiking trail with redwood trees", coffee: "in a cozy coffee shop", gym: "in a bright gym",
  climbing: "at a climbing gym", cycling: "with a bicycle on a city street", beach: "at Ocean Beach at golden hour",
  dogs: "in a park with a dog", cats: "at home with a cat", cooking: "in a sunny kitchen", books: "in a bookstore",
  music: "at a record store", vinyl: "at a record store", art: "in an art gallery", travel: "on a ferry deck",
  running: "on a waterfront path", brunch: "at a brunch cafe", bars: "in a dim cocktail bar", photography: "holding a camera on a city street",
};
// Slots whose first render came out broken (extra limbs, melted hands): bump the seed to re-roll them.
const RESEED: Record<string, number> = { "6-1": 1, "35-1": 1 };
const out = [];
for (let i = 0; i < 40; i++) {
  const p = buildProfile(i, { latitude: 37.7749, longitude: -122.4194 });
  const n = Math.min(p.photoCount, 2);
  const look = LOOKS[(i * 7) % LOOKS.length], hair = HAIR[(i * 5) % HAIR.length], top = TOPS[(i * 3) % TOPS.length];
  // Everyone on the app is 18+; keep younger profiles clearly adult in the photos too.
  const young = p.age < 26 ? ", light stubble, mature adult face" : "";
  const tagScene = p.tags.map((t) => SCENES[t]).find(Boolean);
  const scenes = ["soft window light, plain background", tagScene ?? "on a San Francisco street, Victorian houses behind"];
  for (let k = 0; k < n; k++) {
    const explicitSlot = p.explicitPhoto && k === p.photoCount - 1 && p.photoCount > 1;
    if (explicitSlot) continue;
    const framing = k === 0 ? "head and shoulders portrait photo" : "candid half-body photo";
    out.push({ file: `${i}-${k}.jpg`, seed: i * 100 + k + 10_000 * (RESEED[`${i}-${k}`] ?? 0),
      prompt: `${framing} of a ${p.age} year old ${look} man with ${hair}${young}, wearing ${top}, ${scenes[k]}, friendly expression, natural light, 35mm photo, realistic, sharp focus` });
  }
}
console.log(JSON.stringify(out, null, 1));
