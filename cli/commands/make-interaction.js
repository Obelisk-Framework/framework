const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeInteraction(name) {
  console.log(chalk.blue('\n🎯 Obelisk Interaction Generator\n'));
  
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Interaction name (e.g., ATM):',
        validate: (input) => input.length > 0 || 'Interaction name is required'
      }
    ]);
    name = answer.name;
  }
  
  const interactionName = name.charAt(0).toUpperCase() + name.slice(1);
  
  const details = await inquirer.prompt([
    {
      type: 'input',
      name: 'label',
      message: 'Interaction label (shown to player):',
      default: `Use ${name}`
    },
    {
      type: 'input',
      name: 'actionId',
      message: 'Action ID to trigger:',
      default: name.toLowerCase().replace(/\s+/g, '_')
    },
    {
      type: 'list',
      name: 'location',
      message: 'Where should the interaction be created?',
      choices: ['Module', 'Plugin']
    }
  ]);
  
  let interactionDir;
  
  if (details.location === 'Module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found.'));
      return;
    }
    
    const moduleChoice = await inquirer.prompt([
      { type: 'list', name: 'module', message: 'Select module:', choices: modules }
    ]);
    
    interactionDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'interactions');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found.'));
      return;
    }
    
    const pluginChoice = await inquirer.prompt([
      { type: 'list', name: 'plugin', message: 'Select plugin:', choices: plugins }
    ]);
    
    interactionDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'interactions');
  }
  
  await fs.ensureDir(interactionDir);
  
  const filePath = path.join(interactionDir, `${interactionName}Interaction.lua`);
  
  const interactionContent = `--- ${interactionName} Interaction
--- Registers an interaction point in the world

-- Example coordinates (update these)
local interactions = {
    {
        x = 0.0,
        y = 0.0,
        z = 0.0,
        range = 2.0,
        label = '${details.label}',
        action = '${details.actionId}'
    },
    -- Add more interaction points here
}

-- Register all interaction points
Citizen.CreateThread(function()
    for _, interaction in ipairs(interactions) do
        local interactionId = InteractionService.register({
            x = interaction.x,
            y = interaction.y,
            z = interaction.z,
            range = interaction.range,
            label = interaction.label,
            action = interaction.action
        })
        
        print('[${interactionName}] Registered interaction #' .. interactionId)
        
        -- Optional: Attach policies
        -- PolicyService.attach('interaction', interactionId, 'withinDistance', {
        --     distance = 5.0,
        --     coords = {x = interaction.x, y = interaction.y, z = interaction.z}
        -- })
    end
end)
`;
  
  await fs.writeFile(filePath, interactionContent);
  
  console.log(chalk.green(`\n✓ Interaction created successfully!`));
  console.log(chalk.gray(`\n  Location: ${filePath}`));
  console.log(chalk.yellow(`\n  ⚠️  Don't forget to:`));
  console.log(chalk.gray(`  1. Update the coordinates in the file`));
  console.log(chalk.gray(`  2. Create the '${details.actionId}' action if it doesn't exist\n`));
}

async function getDirectories(source) {
  try {
    const items = await fs.readdir(source, { withFileTypes: true });
    return items.filter(item => item.isDirectory()).map(item => item.name);
  } catch (error) {
    return [];
  }
}

module.exports = makeInteraction;
