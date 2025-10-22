const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeMigration(name) {
  console.log(chalk.blue('\n📊 Obelisk Migration Generator\n'));
  
  // Prompt for migration name if not provided
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Migration name (e.g., create_users_table):',
        validate: (input) => input.length > 0 || 'Migration name is required'
      }
    ]);
    name = answer.name;
  }
  
  // Ask for location
  const location = await inquirer.prompt([
    {
      type: 'list',
      name: 'location',
      message: 'Where should the migration be created?',
      choices: [
        { name: 'Core', value: 'core' },
        { name: 'Module', value: 'module' },
        { name: 'Plugin', value: 'plugin' }
      ]
    }
  ]);
  
  let migrationDir;
  let migrationsJsonPath;
  
  if (location.location === 'core') {
    migrationDir = path.join(process.cwd(), 'core', 'server', 'database', 'migrations');
    migrationsJsonPath = path.join(process.cwd(), 'core', 'server', 'database', 'migrations.json');
  } else if (location.location === 'module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found. Create a module first.'));
      return;
    }
    
    const moduleChoice = await inquirer.prompt([
      {
        type: 'list',
        name: 'module',
        message: 'Select module:',
        choices: modules
      }
    ]);
    
    migrationDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'migrations');
    migrationsJsonPath = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'migrations.json');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found. Create a plugin first.'));
      return;
    }
    
    const pluginChoice = await inquirer.prompt([
      {
        type: 'list',
        name: 'plugin',
        message: 'Select plugin:',
        choices: plugins
      }
    ]);
    
    migrationDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'migrations');
    migrationsJsonPath = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'migrations.json');
  }
  
  // Ensure directory exists
  await fs.ensureDir(migrationDir);
  
  // Generate migration file with yyyy_mm_dd_time format
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  const hours = String(now.getHours()).padStart(2, '0');
  const minutes = String(now.getMinutes()).padStart(2, '0');
  const seconds = String(now.getSeconds()).padStart(2, '0');
  
  const migrationName = `${year}_${month}_${day}_${hours}${minutes}${seconds}_${name}`;
  const fileName = `${migrationName}.lua`;
  const filePath = path.join(migrationDir, fileName);
  
  // Detect if it's a create table migration
  const isCreateTable = name.includes('create') && name.includes('table');
  let tableName = '';
  
  if (isCreateTable) {
    const match = name.match(/create_(\w+)_table/);
    if (match) {
      tableName = match[1];
    }
  }
  
  const migrationContent = isCreateTable ? `--- Migration: Create ${tableName} table
return {
    up = function()
         Schema.create('${tableName}', function(table)
             table:id()
             -- Add your columns here
             table:string('name', 255):notNullable()
             table:timestamps()
         end)
         
         print('[Migration] Created ${tableName} table')
     end,
     
     down = function()
         Schema.drop('${tableName}')
         print('[Migration] Dropped ${tableName} table')
     end
 }
 ` : `--- Migration: ${name}
 return {
     up = function()
         -- Add your migration logic here
         Schema.table('your_table', function(table)
             -- Example: table:string('new_column')
         end)
         
         print('[Migration] Applied ${name}')
     end,
     
     down = function()
         -- Add your rollback logic here
         
         print('[Migration] Rolled back ${name}')
     end
 }
 `;
  
  await fs.writeFile(filePath, migrationContent);
  
  // Add migration to migrations.json
  try {
    let migrationsData = { migrations: [] };
    
    if (await fs.pathExists(migrationsJsonPath)) {
      migrationsData = await fs.readJson(migrationsJsonPath);
    }
    
    if (!migrationsData.migrations) {
      migrationsData.migrations = [];
    }
    
    if (!migrationsData.migrations.includes(migrationName)) {
      migrationsData.migrations.push(migrationName);
    }
    
    await fs.writeJson(migrationsJsonPath, migrationsData, { spaces: 2 });
  } catch (error) {
    console.log(chalk.yellow(`\n⚠ Warning: Could not update migrations.json: ${error.message}`));
  }
  
  console.log(chalk.green(`\n✓ Migration created successfully!`));
  console.log(chalk.gray(`\n  Location: ${filePath}\n`));
}

async function getDirectories(source) {
  try {
    const items = await fs.readdir(source, { withFileTypes: true });
    return items
      .filter(item => item.isDirectory())
      .map(item => item.name);
  } catch (error) {
    return [];
  }
}

module.exports = makeMigration;
