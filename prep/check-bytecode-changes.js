#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

// Main contracts to check for bytecode changes
// When any dependency (parent contracts, libraries, interfaces) changes,
// it will be reflected in the bytecode of these contracts
const CONTRACTS_TO_CHECK = [
  "IthacaAccount.sol/IthacaAccount.json",
  "Orchestrator.sol/Orchestrator.json",
];

function getBytecodeHash(artifactPath) {
  try {
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const bytecode = artifact.bytecode?.object || "";

    if (!bytecode || bytecode === "0x") {
      console.warn(`Warning: No bytecode found in ${artifactPath}`);
      return null;
    }

    // Remove metadata hash from bytecode (last 43 bytes for Solidity)
    // This ensures we only compare actual code changes, not metadata
    const cleanBytecode = bytecode.slice(0, -86); // 43 bytes = 86 hex chars

    return crypto.createHash("sha256").update(cleanBytecode).digest("hex");
  } catch (error) {
    console.error(`Error reading artifact ${artifactPath}:`, error.message);
    return null;
  }
}

function compareArtifacts(baseDir, prDir) {
  const changes = [];

  for (const contract of CONTRACTS_TO_CHECK) {
    const basePath = path.join(baseDir, contract);
    const prPath = path.join(prDir, contract);

    const baseHash = getBytecodeHash(basePath);
    const prHash = getBytecodeHash(prPath);

    if (baseHash && prHash && baseHash !== prHash) {
      changes.push(contract);
      console.log(`Bytecode changed: ${contract}`);
    }
  }

  return changes;
}

function checkVersionBump() {
  try {
    // Check if package.json has been modified in this PR
    const gitStatus = require("child_process")
      .execSync("git diff --name-only origin/$GITHUB_BASE_REF...HEAD", {
        encoding: "utf8",
      })
      .trim()
      .split("\n");

    return gitStatus.includes("package.json");
  } catch (error) {
    console.error("Error checking git status:", error.message);
    return false;
  }
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2) {
    console.error(
      "Usage: check-bytecode-changes.js <base-artifacts-dir> <pr-artifacts-dir>"
    );
    process.exit(1);
  }

  const [baseDir, prDir] = args;

  console.log("Checking bytecode changes...");
  const changes = compareArtifacts(baseDir, prDir);

  if (changes.length > 0) {
    console.log(`\nFound bytecode changes in ${changes.length} contracts`);

    const versionBumped = checkVersionBump();

    if (!versionBumped) {
      console.log("Version has not been bumped - automatic bump required");
      // Use modern GitHub Actions output syntax
      console.log(`::set-output name=needs_version_bump::true`);
      fs.appendFileSync(
        process.env.GITHUB_OUTPUT || "/dev/null",
        "needs_version_bump=true\n"
      );
    } else {
      console.log("Version has already been bumped");
      console.log(`::set-output name=needs_version_bump::false`);
      fs.appendFileSync(
        process.env.GITHUB_OUTPUT || "/dev/null",
        "needs_version_bump=false\n"
      );
    }
  } else {
    console.log("No bytecode changes detected");
    console.log(`::set-output name=needs_version_bump::false`);
    fs.appendFileSync(
      process.env.GITHUB_OUTPUT || "/dev/null",
      "needs_version_bump=false\n"
    );
  }
}

if (require.main === module) {
  main();
}
