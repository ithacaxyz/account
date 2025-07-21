#!/usr/bin/env node
const { readSync, writeSync, forEachWalkSync } = require('./common.js');

async function main() {
  // Get contracts to bump from environment variable or command line
  const contractsToBump = process.env.CONTRACTS_TO_BUMP 
    ? process.env.CONTRACTS_TO_BUMP.split(',')
    : process.argv.slice(2);

  if (contractsToBump.length === 0) {
    console.error('No contracts specified to bump. Usage: update-version.js [contract1] [contract2] ...');
    console.error('Or set CONTRACTS_TO_BUMP environment variable');
    process.exit(1);
  }

  console.log(`Contracts to bump versions: ${contractsToBump.join(', ')}`);

  const versionRegex = /version = "(\d+\.\d+\.\d+)";/;

  forEachWalkSync(['src'], srcPath => {
    if (!srcPath.match(/\.sol$/i)) return;
    
    const src = readSync(srcPath);
    if (src.indexOf('_domainNameAndVersion()') === -1) return;

    // Extract contract name from the file - match actual contract declarations
    // This regex ensures we're matching actual contract definitions, not just any "contract" word
    const contractNameMatch = src.match(/^\s*(?:abstract\s+)?contract\s+(\w+)/m);
    if (!contractNameMatch) return;
    
    const contractName = contractNameMatch[1];
    
    // Only update if this contract is in the list to bump
    if (!contractsToBump.includes(contractName)) {
      console.log(`Skipping ${contractName} - not in bump list`);
      return;
    }

    const match = src.match(versionRegex);
    if (match) {
      const oldVersion = match[1];
      const versionParts = oldVersion.split('.');
      const patch = parseInt(versionParts[2]) + 1;
      const newVersion = `${versionParts[0]}.${versionParts[1]}.${patch}`;
      
      console.log(`Updating version in: ${srcPath} (${oldVersion} -> ${newVersion})`);
      const updatedSrc = src.replace(versionRegex, `version = "${newVersion}";`);
      writeSync(srcPath, updatedSrc);
    } else {
      console.warn(`Version string not found in: ${srcPath}`);
    }
  });
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});