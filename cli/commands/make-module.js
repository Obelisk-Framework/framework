const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeModule(name) {
  console.log(chalk.blue('\n🔨 Obelisk Module Generator\n'));
  
  // Prompt for module name if not provided
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Module name:',
        validate: (input) => input.length > 0 || 'Module name is required'
      }
    ]);
    name = answer.name;
  }
  
  // Convert to PascalCase for class names
  const moduleName = name.charAt(0).toUpperCase() + name.slice(1);
  const moduleDir = path.join(process.cwd(), 'modules', moduleName);
  
  // Check if module already exists
  if (await fs.pathExists(moduleDir)) {
    console.log(chalk.red(`✗ Module ${moduleName} already exists`));
    return;
  }
  
  // Ask which features to include
  const features = await inquirer.prompt([
    {
      type: 'checkbox',
      name: 'features',
      message: 'Select features to include:',
      choices: [
        { name: 'Database Model', value: 'model', checked: true },
        { name: 'Database Migration', value: 'migration', checked: true },
        { name: 'Database Seeder', value: 'seeder' },
        { name: 'Actions', value: 'actions', checked: true },
        { name: 'Interactions', value: 'interactions' },
        { name: 'Keybinds', value: 'keybinds' },
        { name: 'Policies', value: 'policies' },
        { name: 'Vue Component', value: 'vue' },
        { name: 'Client Services', value: 'client', checked: true },
        { name: 'Server Services', value: 'server', checked: true }
      ]
    }
  ]);
  
  console.log(chalk.cyan(`\n📦 Creating module: ${moduleName}...\n`));
  
  // Create module directory structure
  await fs.ensureDir(moduleDir);
  await fs.ensureDir(path.join(moduleDir, 'server'));
  await fs.ensureDir(path.join(moduleDir, 'client'));
  await fs.ensureDir(path.join(moduleDir, 'shared'));

  // Create README
  const readmeContent = `# ${moduleName} Module

## Description
Add your module description here.

## Features
${features.features.map(f => `- ${f}`).join('\n')}

## Installation
This module loads as part of the \`core\` resource. Restart \`core\` (or the whole server) to pick up this module.

## Usage
Add usage instructions here.
`;
  
  await fs.writeFile(path.join(moduleDir, 'README.md'), readmeContent);

  // Generate selected features
  if (features.features.includes('model')) {
    await generateModel(moduleDir, moduleName);
  }
  
  if (features.features.includes('migration')) {
    await generateMigration(moduleDir, moduleName);
  }
  
  if (features.features.includes('seeder')) {
    await generateSeeder(moduleDir, moduleName);
  }
  
  if (features.features.includes('server')) {
    await generateServerService(moduleDir, moduleName);
  }
  
  if (features.features.includes('client')) {
    await generateClientService(moduleDir, moduleName);
  }
  
  if (features.features.includes('actions')) {
    await fs.ensureDir(path.join(moduleDir, 'server', 'actions'));
    await fs.writeFile(
      path.join(moduleDir, 'server', 'actions', 'Example.lua'),
      `-- Example action for ${moduleName}\nreturn function(source, data)\n    print('[${moduleName}] Example action triggered by player ' .. source)\nend\n`
    );
  }
  
  console.log(chalk.green(`\n✓ Module ${moduleName} created successfully!`));
  console.log(chalk.gray(`\n  Location: ${moduleDir}`));
  console.log(chalk.yellow(`  Run \`obelisk registry:generate\` before starting the server so core picks it up.\n`));
}

async function generateModel(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'server', 'models'));
  
  const modelContent = `--- ${moduleName} Model
${moduleName} = BaseModel:new()
${moduleName}.table = '${moduleName.toLowerCase()}s'
${moduleName}.primaryKey = 'id'
${moduleName}.timestamps = true
${moduleName}.fillable = {'data'}
${moduleName}.hidden = {}
${moduleName}.casts = {data = 'json'}

--- Define relationships here
-- Example: function ${moduleName}:user()
--     return self:belongsTo(User, 'user_id')
-- end

return ${moduleName}
`;
  
  await fs.writeFile(path.join(moduleDir, 'server', 'models', `${moduleName}.lua`), modelContent);
  console.log(chalk.gray(`  ✓ Created model: ${moduleName}.lua`));
}

function buildMigrationTimestamp() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  const hours = String(now.getHours()).padStart(2, '0');
  const minutes = String(now.getMinutes()).padStart(2, '0');
  const seconds = String(now.getSeconds()).padStart(2, '0');
  return `${year}_${month}_${day}_${hours}${minutes}${seconds}`;
}

async function registerMigration(migrationsJsonPath, migrationName) {
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
}

async function generateMigration(moduleDir, moduleName) {
  const migrationsDir = path.join(moduleDir, 'server', 'migrations');
  await fs.ensureDir(migrationsDir);

  const tableName = `${moduleName.toLowerCase()}s`;
  const migrationName = `${buildMigrationTimestamp()}_create_${tableName}_table`;
  const migrationContent = `--- Migration: Create ${tableName} table
return {
    up = function()
        Schema.create('${tableName}', function(table)
            table:id()
            table:json('data')
            table:timestamps()
        end)

        print('[Migration] Created ${tableName} table')
    end,

    down = function()
        Schema.drop('${tableName}')
        print('[Migration] Dropped ${tableName} table')
    end
}
`;

  await fs.writeFile(path.join(migrationsDir, `${migrationName}.lua`), migrationContent);
  await registerMigration(path.join(moduleDir, 'server', 'migrations.json'), migrationName);
  console.log(chalk.gray(`  ✓ Created migration for ${moduleName}`));
}

async function generateSeeder(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'server', 'seeders'));
  
  const seederContent = `--- Seeder: ${moduleName} Data
return {
    run = function()
        print('[Seeder] Seeding ${moduleName} data...')
        
        -- Example seed data
        local items = {
            {data = json.encode({example = 1})},
            {data = json.encode({example = 2})}
        }

        for _, item in ipairs(items) do
            Database.insertSync(
                'INSERT INTO ${moduleName.toLowerCase()}s (data, created_at, updated_at) VALUES (?, ?, ?)',
                {item.data, os.time(), os.time()}
            )
        end
        
        print('[Seeder] Seeded ' .. #items .. ' ${moduleName.toLowerCase()}s')
    end
}
`;
  
  await fs.writeFile(path.join(moduleDir, 'server', 'seeders', `${moduleName}Seeder.lua`), seederContent);
  console.log(chalk.gray(`  ✓ Created seeder for ${moduleName}`));
}

async function generateServerService(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'server', 'services'));
  
  const serviceContent = `--- ${moduleName}Service - Server-side business logic
${moduleName}Service = {}

function ${moduleName}Service.initialize()
    print('[${moduleName}Service] Initialized')
end

--- Add your service methods here

return ${moduleName}Service
`;
  
  await fs.writeFile(path.join(moduleDir, 'server', 'services', `${moduleName}Service.lua`), serviceContent);
  console.log(chalk.gray(`  ✓ Created server service for ${moduleName}`));
}

async function generateClientService(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'client', 'services'));
  
  const serviceContent = `--- ${moduleName}Service - Client-side logic
${moduleName}Service = {}

function ${moduleName}Service.initialize()
    print('[${moduleName}Service] Initialized')
end

--- Add your client methods here

return ${moduleName}Service
`;
  
  await fs.writeFile(path.join(moduleDir, 'client', 'services', `${moduleName}Service.lua`), serviceContent);
  console.log(chalk.gray(`  ✓ Created client service for ${moduleName}`));
}

module.exports = makeModule;
