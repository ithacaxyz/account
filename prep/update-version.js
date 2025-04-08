#!/usr/bin/env node
const { readSync, writeSync, forEachWalkSync } = require('./common.js');

async function main() {
  const newVersion = JSON.parse(readSync('package.json')).version;
  const versionRegex = /version = "(\d+\.\d+\.\d+)";/;

  forEachWalkSync(['src'], srcPath => {
    if (!srcPath.match(/\.sol$/i)) return;
    
    const src = readSync(srcPath);
    if (src.indexOf('_domainNameAndVersion()') === -1) return;

    const match = src.match(versionRegex);
    if (match) {
      const oldVersion = match[1];
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
