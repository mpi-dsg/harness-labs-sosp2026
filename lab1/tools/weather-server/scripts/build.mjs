import { constants } from "node:fs";
import {
  access,
  chmod,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const ROOT = path.dirname(fileURLToPath(new URL("../package.json", import.meta.url)));
const OUTPUT_NAME = "index.bundle.mjs";
const NOTICES_NAME = "THIRD_PARTY_NOTICES.txt";
const ARTIFACT_NAMES = [OUTPUT_NAME, NOTICES_NAME];
const checkOnly = process.argv.includes("--check");
const temporaryDirectory = await mkdtemp(path.join(ROOT, ".bundle-build-"));

function packageDirectoryForInput(inputPath) {
  const marker = `${path.sep}node_modules${path.sep}`;
  const markerIndex = inputPath.lastIndexOf(marker);
  if (markerIndex === -1) return undefined;

  const packagePath = inputPath.slice(markerIndex + marker.length).split(path.sep);
  const packageParts = packagePath[0].startsWith("@") ? packagePath.slice(0, 2) : packagePath.slice(0, 1);
  return path.join(inputPath.slice(0, markerIndex + marker.length), ...packageParts);
}

async function generateThirdPartyNotices(inputPaths) {
  const packageDirectories = new Set(inputPaths.map(packageDirectoryForInput).filter(Boolean));
  const packages = [];

  for (const packageDirectory of packageDirectories) {
    const manifest = JSON.parse(await readFile(path.join(packageDirectory, "package.json"), "utf8"));
    const licenseFile = (await readdir(packageDirectory)).find((name) => /^licen[cs]e(?:\.|$)/i.test(name));
    if (!licenseFile) {
      throw new Error(`Bundled dependency ${manifest.name} has no license file`);
    }
    packages.push({
      name: manifest.name,
      version: manifest.version,
      license: manifest.license ?? "unspecified",
      text: (await readFile(path.join(packageDirectory, licenseFile), "utf8")).trim(),
    });
  }

  packages.sort((left, right) => left.name.localeCompare(right.name));
  const sections = packages.map(
    ({ name, version, license, text }) =>
      `${name} ${version} (${license})\n${"-".repeat(72)}\n${text}`,
  );
  return `THIRD-PARTY SOFTWARE NOTICES\n\n${sections.join("\n\n")}\n`;
}

try {
  const buildResult = await build({
    entryPoints: [path.join(ROOT, "index.js")],
    outfile: path.join(temporaryDirectory, OUTPUT_NAME),
    bundle: true,
    platform: "node",
    format: "esm",
    legalComments: "none",
    metafile: true,
  });
  const notices = await generateThirdPartyNotices(Object.keys(buildResult.metafile.inputs));
  await writeFile(path.join(temporaryDirectory, NOTICES_NAME), notices, "utf8");

  for (const artifactName of ARTIFACT_NAMES) {
    const generatedPath = path.join(temporaryDirectory, artifactName);
    await access(generatedPath, constants.R_OK);

    if (checkOnly) {
      const committedPath = path.join(ROOT, artifactName);
      const [generated, committed] = await Promise.all([
        readFile(generatedPath),
        readFile(committedPath),
      ]);
      if (!generated.equals(committed)) {
        throw new Error(`${artifactName} is stale; run npm run build`);
      }
    } else {
      await rename(generatedPath, path.join(ROOT, artifactName));
    }
  }

  if (!checkOnly) {
    await chmod(path.join(ROOT, OUTPUT_NAME), 0o755);
  }
} finally {
  await rm(temporaryDirectory, { recursive: true, force: true });
}
