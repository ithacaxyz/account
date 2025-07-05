#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

// Contract configuration
// Each contract specifies which other contracts should be bumped when it changes
const CONTRACT_CONFIG = {
  "IthacaAccount.sol/IthacaAccount.json": {
    name: "IthacaAccount",
    bumpsWhenChanged: [], // Account changes don't bump other contracts
  },
  "Orchestrator.sol/Orchestrator.json": {
    name: "Orchestrator",
    bumpsWhenChanged: ["IthacaAccount"], // Orchestrator changes bump Account
  },
  "SimpleFunder.sol/SimpleFunder.json": {
    name: "SimpleFunder",
    bumpsWhenChanged: [], // SimpleFunder changes only bump itself
  },
};

// All contracts to check for bytecode changes
const CONTRACTS_TO_CHECK = Object.keys(CONTRACT_CONFIG);

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
  const changes = {};

  for (const contract of CONTRACTS_TO_CHECK) {
    const basePath = path.join(baseDir, contract);
    const prPath = path.join(prDir, contract);

    const baseHash = getBytecodeHash(basePath);
    const prHash = getBytecodeHash(prPath);

    if (baseHash && prHash && baseHash !== prHash) {
      changes[contract] = true;
      console.log(`Bytecode changed: ${contract}`);
    }
  }

  return changes;
}

function determineContractsToBump(bytecodeChanges) {
  const contractsToBump = new Set();

  for (const [contractPath, changed] of Object.entries(bytecodeChanges)) {
    if (changed) {
      const config = CONTRACT_CONFIG[contractPath];
      
      // The contract itself needs to be bumped
      contractsToBump.add(config.name);
      
      // Also bump any contracts specified in bumpsWhenChanged
      for (const otherContract of config.bumpsWhenChanged) {
        contractsToBump.add(otherContract);
      }
    }
  }

  return Array.from(contractsToBump);
}

function checkSolidityVersions() {
  try {
    // Check if any Solidity files have been modified to update their version
    const gitStatus = require("child_process")
      .execSync("git diff --name-only origin/$GITHUB_BASE_REF...HEAD", {
        encoding: "utf8",
      })
      .trim()
      .split("\n")
      .filter(f => f.endsWith(".sol"));

    return gitStatus.length > 0;
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
  const bytecodeChanges = compareArtifacts(baseDir, prDir);
  const changedContracts = Object.values(bytecodeChanges).filter(Boolean).length;

  if (changedContracts > 0) {
    console.log(`\nFound bytecode changes in ${changedContracts} contracts`);

    // Determine which contracts need version bumps
    const contractsToBump = determineContractsToBump(bytecodeChanges);
    console.log(`\nContracts that need version bumps: ${contractsToBump.join(", ")}`);

    const versionsUpdated = checkSolidityVersions();

    if (!versionsUpdated) {
      console.log("Contract versions have not been bumped - automatic bump required");
      // Use modern GitHub Actions output syntax
      console.log(`::set-output name=needs_version_bump::true`);
      console.log(`::set-output name=contracts_to_bump::${contractsToBump.join(",")}`);
      fs.appendFileSync(
        process.env.GITHUB_OUTPUT || "/dev/null",
        `needs_version_bump=true\ncontracts_to_bump=${contractsToBump.join(",")}\n`
      );
    } else {
      console.log("Contract versions have already been updated");
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