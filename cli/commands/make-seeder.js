const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeSeeder(name) {
  console.log(chalk.blue('\n🌱 Obelisk Seeder Generator\n'));
  
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Seeder name (e.g., UsersSeeder):',
        validate: (input) => input.length > 0 || 'Seeder name is required'
      }
    ]);
    name = answer.name;
  }
  
  // Ensure it ends with 'Seeder'
  if (!name.endsWith('Seeder')) {
    name = name + 'Seeder';
  }
  
  const location = await inquirer.prompt([
    {
      type: 'list',
      name: 'location',
      message: 'Where should the seeder be created?',
      choices: ['Core', 'Module', 'Plugin']
    }
  ]);
  
  let seederDir;
  
  if (location.location === 'Core') {
    seederDir = path.join(process.cwd(), 'core', 'server', 'database', 'seeders');
  } else if (location.location === 'Module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found.'));
      return;
    }
    
    const moduleChoice = await inquirer.prompt([
      { type: 'list', name: 'module', message: 'Select module:', choices: modules }
    ]);
    
    seederDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'seeders');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found.'));
      return;
    }
    
    const pluginChoice = await inquirer.prompt([
      { type: 'list', name: 'plugin', message: 'Select plugin:', choices: plugins }
    ]);
    
    seederDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'seeders');
  }
  
  await fs.ensureDir(seederDir);
  
  const filePath = path.join(seederDir, `${name}.lua`);
  
  const seederContent = `--- Seeder: ${name}
return {
    run = function()
        print('[Seeder] Running ${name}...')
        
        -- Example seed data
        local data = {
            {name = 'Example 1', value = 100},
            {name = 'Example 2', value = 200}
        }
        
        for _, item in ipairs(data) do
            Database.insertSync(
                'INSERT INTO your_table (name, value, created_at, updated_at) VALUES (?, ?, ?, ?)',
                {item.name, item.value, os.time(), os.time()}
            )
        end
        
        print('[Seeder] Seeded ' .. #data .. ' records')
    end
}
`;
  
  await fs.writeFile(filePath, seederContent);
  
  console.log(chalk.green(`\n✓ Seeder created successfully!`));
  console.log(chalk.gray(`\n  Location: ${filePath}\n`));
}

async function getDirectories(source) {
  try {
    const items = await fs.readdir(source, { withFileTypes: true });
    return items.filter(item => item.isDirectory()).map(item => item.name);
  } catch (error) {
    return [];
  }
}

module.exports = makeSeeder;
