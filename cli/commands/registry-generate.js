const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

/**
 * Scans modules/ and plugins/ on disk and regenerates their registry.json
 * files from what's actually there. Replaces the old approach of hand- or
 * CLI-maintained registry entries: Lua can't list directory contents at
 * runtime, so something outside the FXServer sandbox has to produce this
 * file, and scanning disk is the only way that's actually automatic (no
 * developer has to remember to register anything, ever).
 *
 * Must run on the host, not inside the Docker container: core/ is mounted
 * read-only (`:ro` in docker-compose.yml), so a write from inside the
 * container would fail. Run this any time a module/plugin directory is
 * added or removed, before starting (or restarting) the server.
 */
async function registryGenerate() {
  console.log(chalk.blue('\nGenerating modules/plugins registries...\n'));

  await generateOne('modules', 'modules');
  await generateOne('plugins', 'plugins');

  console.log(chalk.green('\nDone.\n'));
}

async function generateOne(dirName, key) {
  const dir = path.join(process.cwd(), dirName);
  const registryPath = path.join(dir, 'registry.json');

  let names = [];
  if (await fs.pathExists(dir)) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    names = entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  }

  await fs.ensureDir(dir);
  await fs.writeJson(registryPath, { [key]: names }, { spaces: 2 });

  console.log(chalk.gray(`  ${dirName}/registry.json: [${names.join(', ')}]`));
}

module.exports = registryGenerate;
