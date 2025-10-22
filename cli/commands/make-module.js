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
  
  // Create fxmanifest.lua
  const manifestContent = `fx_version 'cerulean'
game 'gta5'

author 'Obelisk Framework'
description '${moduleName} Module'
version '1.0.0'

-- Module dependencies
dependencies {
    '/server:5848',
    '/onesync'
}

-- Shared scripts
shared_scripts {
    'shared/**/*.lua'
}

-- Client scripts
client_scripts {
    'client/**/*.lua'
}

-- Server scripts
server_scripts {
    'server/**/*.lua'
}
`;
  
  await fs.writeFile(path.join(moduleDir, 'fxmanifest.lua'), manifestContent);
  
  // Create README
  const readmeContent = `# ${moduleName} Module

## Description
Add your module description here.

## Features
${features.features.map(f => `- ${f}`).join('\n')}

## Installation
This module is automatically loaded by the Obelisk framework.

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
  console.log(chalk.gray(`\n  Location: ${moduleDir}\n`));
}

async function generateModel(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'server', 'models'));
  
  const modelContent = `--- ${moduleName} Model
${moduleName} = BaseModel:new()
${moduleName}.table = '${moduleName.toLowerCase()}s'
${moduleName}.primaryKey = 'id'
${moduleName}.timestamps = true
${moduleName}.fillable = {'name', 'description'}
${moduleName}.hidden = {}

--- Define relationships here
-- Example: function ${moduleName}:user()
--     return self:belongsTo(User, 'user_id')
-- end

return ${moduleName}
`;
  
  await fs.writeFile(path.join(moduleDir, 'server', 'models', `${moduleName}.lua`), modelContent);
  console.log(chalk.gray(`  ✓ Created model: ${moduleName}.lua`));
}

async function generateMigration(moduleDir, moduleName) {
  await fs.ensureDir(path.join(moduleDir, 'server', 'migrations'));
  
  const timestamp = Date.now();
  const migrationContent = `--- Migration: Create ${moduleName.toLowerCase()}s table
return {
    up = function()
        Schema.create('${moduleName.toLowerCase()}s', function(table)
            table:id()
            table:string('name', 255):notNullable()
            table:text('description')
            table:boolean('active'):default(1)
            table:timestamps()
            
            table:index({'name'})
        end)
        
        print('[Migration] Created ${moduleName.toLowerCase()}s table')
    end,
    
    down = function()
        Schema.drop('${moduleName.toLowerCase()}s')
        print('[Migration] Dropped ${moduleName.toLowerCase()}s table')
    end
}
`;
  
  await fs.writeFile(
    path.join(moduleDir, 'server', 'migrations', `${timestamp}_create_${moduleName.toLowerCase()}s_table.lua`),
    migrationContent
  );
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
            {name = 'Example 1', description = 'First example', active = 1},
            {name = 'Example 2', description = 'Second example', active = 1}
        }
        
        for _, item in ipairs(items) do
            Database.insertSync(
                'INSERT INTO ${moduleName.toLowerCase()}s (name, description, active, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
                {item.name, item.description, item.active, os.time(), os.time()}
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
