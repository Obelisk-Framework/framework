const fs = require('fs-extra');

async function appendToRegistry(registryPath, name, key) {
  let data = { [key]: [] };

  if (await fs.pathExists(registryPath)) {
    data = await fs.readJson(registryPath);
  }

  if (!data[key]) {
    data[key] = [];
  }

  if (!data[key].includes(name)) {
    data[key].push(name);
  }

  await fs.writeJson(registryPath, data, { spaces: 2 });
}

module.exports = { appendToRegistry };
