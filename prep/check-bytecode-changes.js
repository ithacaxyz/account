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

function checkManualVersionBumps(contractsToBump) {
  try {
    // Check which specific contracts have already had their versions manually bumped
    const baseRef = process.env.GITHUB_BASE_REF || 'main';
    const alreadyBumpedContracts = [];
    
    // Get the diff for Solidity files
    const gitDiff = require("child_process")
      .execSync(`git diff origin/${baseRef}...HEAD -- src/*.sol`, {
        encoding: "utf8",
      });
    
    // Split diff into file sections
    const fileSections = gitDiff.split(/^diff --git/m).filter(Boolean);
    
    // Check each contract that needs bumping
    for (const contractName of contractsToBump) {
      let foundVersionBump = false;
      
      // Find the file section that contains this contract
      for (const fileSection of fileSections) {
        // Skip if this file section doesn't contain our contract
        if (!fileSection.includes(`contract ${contractName}`)) {
          continue;
        }
        
        // Look for version changes in this file section
        const lines = fileSection.split('\n');
        let currentContract = null;
        let oldVersion = null;
        let newVersion = null;
        
        for (const line of lines) {
          // Track which contract we're currently in based on context lines or added lines
          if (line.match(/^[@\s].*contract\s+(\w+)/)) {
            currentContract = line.match(/contract\s+(\w+)/)[1];
          } else if (line.match(/^\+.*contract\s+(\w+)/)) {
            currentContract = line.match(/contract\s+(\w+)/)[1];
          }
          
          // Only look for version changes if we're in the right contract
          if (currentContract === contractName) {
            // Check for removed version line
            if (line.match(/^-\s*version = "(\d+\.\d+\.\d+)";/)) {
              oldVersion = line.match(/"(\d+\.\d+\.\d+)"/)[1];
            }
            // Check for added version line
            else if (line.match(/^\+\s*version = "(\d+\.\d+\.\d+)";/)) {
              newVersion = line.match(/"(\d+\.\d+\.\d+)"/)[1];
            }
          }
        }
        
        // If we found both old and new versions and they're different, the version was bumped
        if (oldVersion && newVersion && oldVersion !== newVersion) {
          foundVersionBump = true;
          alreadyBumpedContracts.push(contractName);
          console.log(`Contract ${contractName} already manually bumped from ${oldVersion} to ${newVersion}`);
          break;
        }
      }
      
      if (!foundVersionBump) {
        console.log(`Contract ${contractName} needs automatic version bump`);
      }
    }
    
    // Return contracts that still need bumping (not manually bumped)
    return contractsToBump.filter(c => !alreadyBumpedContracts.includes(c));
  } catch (error) {
    console.error("Error checking manual version bumps:", error.message);
    // If there's an error, assume all contracts need bumping
    return contractsToBump;
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

    // Check which contracts have already been manually bumped
    const contractsStillNeedingBump = checkManualVersionBumps(contractsToBump);

    if (contractsStillNeedingBump.length > 0) {
      console.log(`Contracts still needing version bumps: ${contractsStillNeedingBump.join(", ")}`);
      console.log("Automatic bump required for remaining contracts");
      // Use modern GitHub Actions output syntax
      console.log(`::set-output name=needs_version_bump::true`);
      console.log(`::set-output name=contracts_to_bump::${contractsStillNeedingBump.join(",")}`);
      fs.appendFileSync(
        process.env.GITHUB_OUTPUT || "/dev/null",
        `needs_version_bump=true\ncontracts_to_bump=${contractsStillNeedingBump.join(",")}\n`
      );
    } else {
      console.log("All required contract versions have already been updated");
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
