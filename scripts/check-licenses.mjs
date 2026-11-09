import { execFileSync } from "node:child_process";

const allowedLicenses = new Set([
  "(MIT OR CC0-1.0)",
  "0BSD",
  "Apache-2.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "CC0-1.0",
  "ISC",
  "MIT",
  "OFL-1.1",
]);

const output = execFileSync(
  "pnpm",
  ["licenses", "list", "--prod", "--json"],
  { encoding: "utf8", maxBuffer: 20 * 1024 * 1024 },
);
const licenses = JSON.parse(output);
const detectedLicenses = Object.keys(licenses).sort();
const rejectedLicenses = detectedLicenses.filter(
  (license) => !allowedLicenses.has(license),
);

if (rejectedLicenses.length > 0) {
  console.error("Unreviewed or incompatible production dependency licences:");
  for (const license of rejectedLicenses) {
    const packages = licenses[license]
      .map((entry) => `${entry.name}@${entry.versions.join(",")}`)
      .sort();
    console.error(`- ${license}: ${packages.join(", ")}`);
  }
  console.error(
    "Review compatibility with Apache-2.0 before updating the explicit allowlist.",
  );
  process.exit(1);
}

const packageCount = detectedLicenses.reduce(
  (count, license) => count + licenses[license].length,
  0,
);
console.log(
  `Licence compatibility check passed (${packageCount} production packages; ${detectedLicenses.join(", ")}).`,
);
