const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');
const { appendToRegistry } = require('../lib/registry');

async function makePlugin(name) {
  console.log(chalk.blue('\n🔌 Obelisk Plugin Generator\n'));
  
  // Prompt for plugin name if not provided
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Plugin name:',
        validate: (input) => input.length > 0 || 'Plugin name is required'
      }
    ]);
    name = answer.name;
  }
  
  // Convert to PascalCase
  const pluginName = name.charAt(0).toUpperCase() + name.slice(1);
  const pluginDir = path.join(process.cwd(), 'plugins', pluginName);
  
  // Check if plugin already exists
  if (await fs.pathExists(pluginDir)) {
    console.log(chalk.red(`✗ Plugin ${pluginName} already exists`));
    return;
  }
  
  // Ask for plugin details
  const details = await inquirer.prompt([
    {
      type: 'input',
      name: 'description',
      message: 'Plugin description:',
      default: `${pluginName} plugin for Obelisk`
    },
    {
      type: 'input',
      name: 'author',
      message: 'Author name:',
      default: 'Your Name'
    },
    {
      type: 'checkbox',
      name: 'features',
      message: 'Select features to include:',
      choices: [
        { name: 'Database Tables', value: 'database', checked: true },
        { name: 'Actions', value: 'actions', checked: true },
        { name: 'Interactions', value: 'interactions' },
        { name: 'Keybinds', value: 'keybinds' },
        { name: 'Commands', value: 'commands' },
        { name: 'Vue UI Page', value: 'vue', checked: true },
        { name: 'API Endpoints', value: 'api' }
      ]
    }
  ]);
  
  console.log(chalk.cyan(`\n📦 Creating plugin: ${pluginName}...\n`));
  
  // Create plugin directory structure
  await fs.ensureDir(pluginDir);
  await fs.ensureDir(path.join(pluginDir, 'server'));
  await fs.ensureDir(path.join(pluginDir, 'client'));
  await fs.ensureDir(path.join(pluginDir, 'shared'));
  
  if (details.features.includes('vue')) {
    await fs.ensureDir(path.join(pluginDir, 'web'));
  }
  
  // Create config file
  const configContent = `Config = {}

Config.Debug = false

-- Add your plugin configuration here

return Config
`;
  
  await fs.writeFile(path.join(pluginDir, 'shared', 'config.lua'), configContent);
  
  // Generate selected features
  if (details.features.includes('database')) {
    await generatePluginMigration(pluginDir, pluginName);
  }
  
  if (details.features.includes('actions')) {
    await generatePluginActions(pluginDir, pluginName);
  }
  
  if (details.features.includes('commands')) {
    await generatePluginCommands(pluginDir, pluginName);
  }
  
  if (details.features.includes('vue')) {
    await generatePluginVue(pluginDir, pluginName);
  }
  
  // Create main server file
  await generatePluginServer(pluginDir, pluginName, details.features);
  
  // Create main client file
  await generatePluginClient(pluginDir, pluginName, details.features);
  
  // Create README
  const readmeContent = `# ${pluginName} Plugin

## Description
${details.description}

## Author
${details.author}

## Features
${details.features.map(f => `- ${f}`).join('\n')}

## Installation
This plugin loads as part of the \`core\` resource. Place it in the \`plugins/\` directory and restart \`core\` (or the whole server) to pick it up.

## Configuration
Edit \`shared/config.lua\` to configure the plugin.

## Usage
Add usage instructions here.
`;
  
  await fs.writeFile(path.join(pluginDir, 'README.md'), readmeContent);

  await appendToRegistry(
    path.join(process.cwd(), 'plugins', 'registry.json'),
    pluginName,
    'plugins'
  );

  console.log(chalk.green(`\n✓ Plugin ${pluginName} created successfully!`));
  console.log(chalk.gray(`\n  Location: ${pluginDir}`));
  
  if (details.features.includes('vue')) {
    console.log(chalk.yellow(`\n  Note: Run 'npm install' in the web/ directory to set up Vue\n`));
  } else {
    console.log('');
  }
}

async function generatePluginMigration(pluginDir, pluginName) {
  await fs.ensureDir(path.join(pluginDir, 'server', 'migrations'));
  
  const timestamp = Date.now();
  const migrationContent = `--- Migration: Create ${pluginName.toLowerCase()}_data table
return {
    up = function()
        Schema.create('${pluginName.toLowerCase()}_data', function(table)
            table:id()
            table:string('player_identifier', 100):notNullable()
            table:json('data')
            table:timestamps()
            
            table:index({'player_identifier'})
        end)
        
        print('[${pluginName}] Created ${pluginName.toLowerCase()}_data table')
    end,
    
    down = function()
        Schema.drop('${pluginName.toLowerCase()}_data')
        print('[${pluginName}] Dropped ${pluginName.toLowerCase()}_data table')
    end
}
`;
  
  await fs.writeFile(
    path.join(pluginDir, 'server', 'migrations', `${timestamp}_create_${pluginName.toLowerCase()}_table.lua`),
    migrationContent
  );
  console.log(chalk.gray(`  ✓ Created migration`));
}

async function generatePluginActions(pluginDir, pluginName) {
  await fs.ensureDir(path.join(pluginDir, 'server', 'actions'));
  
  const actionContent = `-- Example action for ${pluginName}
return function(source, data)
    print('[${pluginName}] Example action triggered by player ' .. source)
    
    -- Add your action logic here
    NotificationService.success(source, '${pluginName}', 'Action executed successfully!')
end
`;
  
  await fs.writeFile(path.join(pluginDir, 'server', 'actions', 'ExampleAction.lua'), actionContent);
  console.log(chalk.gray(`  ✓ Created example action`));
}

async function generatePluginCommands(pluginDir, pluginName) {
  await fs.ensureDir(path.join(pluginDir, 'server', 'commands'));
  
  const commandContent = `-- Example command for ${pluginName}
RegisterCommand('${pluginName.toLowerCase()}', function(source, args, rawCommand)
    local player = source
    
    -- Add your command logic here
    NotificationService.info(player, '${pluginName}', 'Command executed!')
end, false)
`;
  
  await fs.writeFile(path.join(pluginDir, 'server', 'commands', 'ExampleCommand.lua'), commandContent);
  console.log(chalk.gray(`  ✓ Created example command`));
}

async function generatePluginVue(pluginDir, pluginName) {
  const webDir = path.join(pluginDir, 'web');
  
  // Create basic Vue structure
  await fs.ensureDir(path.join(webDir, 'src', 'components'));
  await fs.ensureDir(path.join(webDir, 'public'));
  
  // package.json
  const packageJson = {
    name: pluginName.toLowerCase(),
    version: '1.0.0',
    private: true,
    scripts: {
      dev: 'vite',
      build: 'vite build'
    },
    dependencies: {
      vue: '^3.5.22'
    },
    devDependencies: {
      '@vitejs/plugin-vue': '^6.0.1',
      'vite': '^7.1.7',
      'tailwindcss': '^3.4.18',
      'autoprefixer': '^10.4.21',
      'postcss': '^8.5.6'
    }
  };
  
  await fs.writeJSON(path.join(webDir, 'package.json'), packageJson, { spaces: 2 });
  
  // Vue component
  const componentContent = `<template>
  <div class="p-4">
    <h1 class="text-2xl font-bold text-white">${pluginName}</h1>
    <p class="text-gray-400 mt-2">Welcome to ${pluginName} plugin</p>
  </div>
</template>

<script setup>
import { ref } from 'vue'

// Add your component logic here
</script>
`;
  
  await fs.writeFile(path.join(webDir, 'src', 'components', `${pluginName}.vue`), componentContent);
  
  console.log(chalk.gray(`  ✓ Created Vue UI structure`));
}

async function generatePluginServer(pluginDir, pluginName, features) {
  await fs.ensureDir(path.join(pluginDir, 'server'));
  
  const serverContent = `--- ${pluginName} Plugin - Server Main
print('[${pluginName}] Loading...')

-- Initialize plugin
Citizen.CreateThread(function()
    ${features.includes('database') ? '-- Run migrations\n    -- Add migration runner here' : ''}
    
    print('[${pluginName}] Loaded successfully!')
end)

-- Register actions
${features.includes('actions') ? `ActionService.register('${pluginName.toLowerCase()}_example', function(source, data)
    print('[${pluginName}] Action triggered')
end)` : ''}
`;
  
  await fs.writeFile(path.join(pluginDir, 'server', 'main.lua'), serverContent);
  console.log(chalk.gray(`  ✓ Created server main file`));
}

async function generatePluginClient(pluginDir, pluginName, features) {
  await fs.ensureDir(path.join(pluginDir, 'client'));
  
  const clientContent = `--- ${pluginName} Plugin - Client Main
print('[${pluginName}] Client loading...')

-- Initialize client-side logic
Citizen.CreateThread(function()
    print('[${pluginName}] Client loaded successfully!')
end)
`;
  
  await fs.writeFile(path.join(pluginDir, 'client', 'main.lua'), clientContent);
  console.log(chalk.gray(`  ✓ Created client main file`));
}

module.exports = makePlugin;
