const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makePolicy(name) {
  console.log(chalk.blue('\n🔒 Obelisk Policy Generator\n'));
  
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Policy name (e.g., HasPermission):',
        validate: (input) => input.length > 0 || 'Policy name is required'
      }
    ]);
    name = answer.name;
  }
  
  const policyName = name.charAt(0).toUpperCase() + name.slice(1);
  
  const details = await inquirer.prompt([
    {
      type: 'input',
      name: 'policyId',
      message: 'Policy ID (camelCase):',
      default: name.charAt(0).toLowerCase() + name.slice(1)
    },
    {
      type: 'input',
      name: 'description',
      message: 'Policy description:',
      default: `Checks if ${name.toLowerCase()} requirement is met`
    },
    {
      type: 'list',
      name: 'location',
      message: 'Where should the policy be created?',
      choices: ['Core', 'Module', 'Plugin']
    }
  ]);
  
  let policyDir;
  
  if (details.location === 'Core') {
    policyDir = path.join(process.cwd(), 'core', 'server', 'Policies');
  } else if (details.location === 'Module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found.'));
      return;
    }
    
    const moduleChoice = await inquirer.prompt([
      { type: 'list', name: 'module', message: 'Select module:', choices: modules }
    ]);
    
    policyDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'policies');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found.'));
      return;
    }
    
    const pluginChoice = await inquirer.prompt([
      { type: 'list', name: 'plugin', message: 'Select plugin:', choices: plugins }
    ]);
    
    policyDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'policies');
  }
  
  await fs.ensureDir(policyDir);
  
  const filePath = path.join(policyDir, `${policyName}Policy.lua`);
  
  const policyContent = `--- ${policyName} Policy
--- ${details.description}
--- Policy ID: ${details.policyId}

--- Policy validator function
--- @param source number Player server ID
--- @param resource table Resource being accessed {type, id}
--- @param config table Configuration from pivot data
--- @return boolean allowed
--- @return string reason Optional denial reason
local function ${details.policyId}Validator(source, resource, config)
    -- Get player information
    local playerPed = GetPlayerPed(source)
    
    if not DoesEntityExist(playerPed) then
        return false, 'Player not found'
    end
    
    -- Add your validation logic here
    -- Example: Check if player has a specific item
    -- local hasItem = Inventory.hasItem(source, config.item_id)
    -- if not hasItem then
    --     return false, 'You need a specific item'
    -- end
    
    -- Example: Check player level
    -- local playerLevel = GetPlayerLevel(source)
    -- if playerLevel < (config.min_level or 0) then
    --     return false, 'Your level is too low'
    -- end
    
    -- Example: Check distance
    -- if config.coords then
    --     local coords = GetEntityCoords(playerPed)
    --     local dist = #(vector3(coords.x, coords.y, coords.z) - 
    --                    vector3(config.coords.x, config.coords.y, config.coords.z))
    --     
    --     if dist > (config.max_distance or 5.0) then
    --         return false, 'You are too far away'
    --     end
    -- end
    
    -- Policy passed
    return true
end

-- Register the policy
PolicyService.register('${details.policyId}', ${details.policyId}Validator, {
    description = '${details.description}'
})

print('[Policy] Registered ${details.policyId} policy')
`;
  
  await fs.writeFile(filePath, policyContent);
  
  console.log(chalk.green(`\n✓ Policy created successfully!`));
  console.log(chalk.gray(`\n  Location: ${filePath}`));
  console.log(chalk.gray(`\n  Usage example:`));
  console.log(chalk.cyan(`  PolicyService.attach('interaction', interactionId, '${details.policyId}', {`));
  console.log(chalk.cyan(`      -- config options here`));
  console.log(chalk.cyan(`  })\n`));
}

async function getDirectories(source) {
  try {
    const items = await fs.readdir(source, { withFileTypes: true });
    return items.filter(item => item.isDirectory()).map(item => item.name);
  } catch (error) {
    return [];
  }
}

module.exports = makePolicy;
