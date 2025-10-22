const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeAction(name) {
  console.log(chalk.blue('\n⚡ Obelisk Action Generator\n'));
  
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Action name (e.g., OpenDoor):',
        validate: (input) => input.length > 0 || 'Action name is required'
      }
    ]);
    name = answer.name;
  }
  
  const actionName = name.charAt(0).toUpperCase() + name.slice(1);
  
  const details = await inquirer.prompt([
    {
      type: 'input',
      name: 'actionId',
      message: 'Action ID (snake_case):',
      default: name.replace(/([A-Z])/g, '_$1').toLowerCase().replace(/^_/, '')
    },
    {
      type: 'list',
      name: 'location',
      message: 'Where should the action be created?',
      choices: ['Core', 'Module', 'Plugin']
    }
  ]);
  
  let actionDir;
  
  if (details.location === 'Core') {
    actionDir = path.join(process.cwd(), 'core', 'server', 'actions');
  } else if (details.location === 'Module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found.'));
      return;
    }
    
    const moduleChoice = await inquirer.prompt([
      { type: 'list', name: 'module', message: 'Select module:', choices: modules }
    ]);
    
    actionDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'actions');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found.'));
      return;
    }
    
    const pluginChoice = await inquirer.prompt([
      { type: 'list', name: 'plugin', message: 'Select plugin:', choices: plugins }
    ]);
    
    actionDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'actions');
  }
  
  await fs.ensureDir(actionDir);
  
  const filePath = path.join(actionDir, `${actionName}.lua`);
  
  const actionContent = `--- ${actionName} Action
--- Action ID: ${details.actionId}
--- Triggered by: keybinds, interactions, or manual calls

return function(source, data)
    print('[${actionName}] Triggered by player ' .. source)
    
    -- Validate player exists
    if not source or source == 0 then
        print('[${actionName}] Invalid player source')
        return
    end
    
    -- Get player data
    local playerPed = GetPlayerPed(source)
    if not DoesEntityExist(playerPed) then
        print('[${actionName}] Player entity does not exist')
        return
    end
    
    -- Your action logic here
    -- Example: Check conditions
    local canPerformAction = true
    
    if not canPerformAction then
        NotificationService.error(source, '${actionName}', 'Cannot perform this action')
        return
    end
    
    -- Execute action
    -- Add your logic here
    
    -- Send success notification
    NotificationService.success(source, '${actionName}', 'Action completed successfully')
    
    -- Trigger client-side effects if needed
    -- TriggerClientEvent('obelisk:${details.actionId}:execute', source, data)
end
`;
  
  await fs.writeFile(filePath, actionContent);
  
  console.log(chalk.green(`\n✓ Action created successfully!`));
  console.log(chalk.gray(`\n  Location: ${filePath}`));
  console.log(chalk.gray(`\n  Remember to register this action in your initialization code:`));
  console.log(chalk.cyan(`  ActionService.register('${details.actionId}', require('${filePath}'))\n`));
}

async function getDirectories(source) {
  try {
    const items = await fs.readdir(source, { withFileTypes: true });
    return items.filter(item => item.isDirectory()).map(item => item.name);
  } catch (error) {
    return [];
  }
}

module.exports = makeAction;
