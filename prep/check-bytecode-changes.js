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
    const versionRegex = /version = "(\d+\.\d+\.\d+)";/;
    const alreadyBumpedContracts = [];
    
    // Get the diff for Solidity files
    const gitDiff = require("child_process")
      .execSync(`git diff origin/${baseRef}...HEAD -- src/*.sol`, {
        encoding: "utf8",
      });
    
    // Check each contract that needs bumping
    for (const contractName of contractsToBump) {
      // Look for version changes for this specific contract in the diff
      const contractPattern = new RegExp(`contract\\s+${contractName}[\\s\\S]*?version = "\\d+\\.\\d+\\.\\d+";`, 'g');
      const contractSection = gitDiff.match(contractPattern);
      
      if (contractSection) {
        // Check if there's a version change in this contract's section
        const lines = gitDiff.split('\n');
        let inContract = false;
        let foundVersionChange = false;
        
        for (const line of lines) {
          if (line.includes(`contract ${contractName}`)) {
            inContract = true;
          }
          if (inContract && line.startsWith('+') && versionRegex.test(line) && !line.startsWith('+++')) {
            foundVersionChange = true;
            alreadyBumpedContracts.push(contractName);
            break;
          }
          if (inContract && line.includes('contract ') && !line.includes(contractName)) {
            // We've moved to a different contract
            break;
          }
        }
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
