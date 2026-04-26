// CP Scripts License Key Generator
// Usage: node keygen.js [product] [count]
// Products: BUNDLE, FX_CONSTELLATION, CUSTOM_TOOLBARS, MEDIA_PROPERTIES, CP_STUDIO

const PRODUCTS = {
    BUNDLE: "CP_BUNDLE",
    FX_CONSTELLATION: "CP_FXCON",
    CUSTOM_TOOLBARS: "CP_CTOOL",
    MEDIA_PROPERTIES: "CP_MPTBR",
    CP_STUDIO: "CP_STUD",
};

// Simple seeded PRNG (matches Lua's math.random behavior for key gen)
function seededRandom(seed) {
    // LCG matching Lua 5.3's internal PRNG
    let s = seed;
    return function (min, max) {
        s = (s * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
        const val = Number((s >> 33n) & 0x7FFFFFFFn);
        return min + (val % (max - min + 1));
    };
}

// Lua-compatible key generation using actual Lua math.random sequence
// Since we can't perfectly replicate Lua's PRNG, we use our own deterministic one
function generateKey(salt, seed) {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let key = "";
    const rng = seededRandom(BigInt(seed));
    for (let i = 1; i <= 16; i++) {
        const idx = rng(0, chars.length - 1);
        key += chars[idx];
        if (i % 4 === 0 && i < 16) key += "-";
    }

    // Compute checksum (this part is deterministic, matches Lua exactly)
    const data = salt + key;
    let hash = 0;
    for (let i = 0; i < data.length; i++) {
        hash = (hash * 31 + data.charCodeAt(i)) % 1000000007;
    }
    let checksum = 12345 - (hash % 54321);
    if (checksum < 0) checksum += 54321;
    const checkChar = chars[(checksum % chars.length)];

    return key + checkChar;
}

function validate(key, salt) {
    if (!key || key.length < 20) return false;
    const keyBody = key.slice(0, -1);
    const checkChar = key.slice(-1);

    const data = salt + keyBody;
    let hash = 0;
    for (let i = 0; i < data.length; i++) {
        hash = (hash * 31 + data.charCodeAt(i)) % 1000000007;
    }
    let checksum = 12345 - (hash % 54321);
    if (checksum < 0) checksum += 54321;
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const expected = chars[(checksum % chars.length)];
    return checkChar === expected;
}

// Parse args
const product = process.argv[2] || null;
const count = parseInt(process.argv[3]) || 1;

if (!product) {
    console.log("CP Scripts License Key Generator");
    console.log("================================\n");
    console.log("Usage: node keygen.js <product> [count]\n");
    console.log("Products:");
    for (const [name, salt] of Object.entries(PRODUCTS)) {
        console.log(`  ${name}  (salt: ${salt})`);
    }
    console.log("\nExamples:");
    console.log("  node keygen.js BUNDLE");
    console.log("  node keygen.js FX_CONSTELLATION 5");
    console.log("  node keygen.js ALL");
    process.exit(0);
}

const baseSeed = Date.now();

if (product === "ALL") {
    console.log("CP Scripts - License Keys (all products)");
    console.log("========================================\n");
    for (const [name, salt] of Object.entries(PRODUCTS)) {
        const key = generateKey(salt, baseSeed + name.length);
        const valid = validate(key, salt);
        console.log(`${name.padEnd(20)} ${key}  [${valid ? "OK" : "FAIL"}]`);
    }
} else {
    const salt = PRODUCTS[product];
    if (!salt) {
        console.error(`ERROR: Unknown product '${product}'`);
        console.error("Valid: BUNDLE, FX_CONSTELLATION, CUSTOM_TOOLBARS, MEDIA_PROPERTIES, CP_STUDIO");
        process.exit(1);
    }
    console.log(`CP Scripts - ${product} License Keys`);
    console.log("=".repeat(40) + "\n");
    for (let i = 1; i <= count; i++) {
        const key = generateKey(salt, baseSeed + i);
        const valid = validate(key, salt);
        console.log(`${key}  [${valid ? "OK" : "FAIL"}]`);
    }
}
