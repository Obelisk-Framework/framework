const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

async function makeModel(name) {
  console.log(chalk.blue('\n🗄️  Obelisk Model Generator\n'));
  
  if (!name) {
    const answer = await inquirer.prompt([
      {
        type: 'input',
        name: 'name',
        message: 'Model name (singular, e.g., User):',
        validate: (input) => input.length > 0 || 'Model name is required'
      }
    ]);
    name = answer.name;
  }
  
  const modelName = name.charAt(0).toUpperCase() + name.slice(1);
  
  const details = await inquirer.prompt([
    {
      type: 'input',
      name: 'table',
      message: 'Table name (plural):',
      default: modelName.toLowerCase() + 's'
    },
    {
      type: 'list',
      name: 'location',
      message: 'Where should the model be created?',
      choices: [
        { name: 'Core', value: 'core' },
        { name: 'Module', value: 'module' },
        { name: 'Plugin', value: 'plugin' }
      ]
    }
  ]);
  
  let modelDir;
  
  if (details.location === 'core') {
    modelDir = path.join(process.cwd(), 'core', 'server', 'Models');
  } else if (details.location === 'module') {
    const modules = await getDirectories(path.join(process.cwd(), 'modules'));
    if (modules.length === 0) {
      console.log(chalk.yellow('No modules found.'));
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
    
    modelDir = path.join(process.cwd(), 'modules', moduleChoice.module, 'server', 'models');
  } else {
    const plugins = await getDirectories(path.join(process.cwd(), 'plugins'));
    if (plugins.length === 0) {
      console.log(chalk.yellow('No plugins found.'));
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
    
    modelDir = path.join(process.cwd(), 'plugins', pluginChoice.plugin, 'server', 'models');
  }
  
  await fs.ensureDir(modelDir);
  
  const filePath = path.join(modelDir, `${modelName}.lua`);
  
  if (await fs.pathExists(filePath)) {
    console.log(chalk.red(`✗ Model ${modelName} already exists`));
    return;
  }
  
  const modelContent = `--- ${modelName} Model
${modelName} = {}
setmetatable(${modelName}, { __index = BaseModel })

-- Table configuration
${modelName}.table = '${details.table}'
${modelName}.primaryKey = 'id'
${modelName}.timestamps = true
${modelName}.fillable = {'name', 'description'}
${modelName}.hidden = {}
${modelName}.casts = {}

--- Create a new ${modelName} instance
--- @param attributes table
--- @return ${modelName}
function ${modelName}.new(attributes)
    local instance = BaseModel.new(attributes)
    setmetatable(instance, { __index = ${modelName} })
    
    -- Copy class properties
    instance.table = ${modelName}.table
    instance.primaryKey = ${modelName}.primaryKey
    instance.timestamps = ${modelName}.timestamps
    instance.fillable = ${modelName}.fillable
    instance.hidden = ${modelName}.hidden
    instance.casts = ${modelName}.casts
    
    return instance
end

--- Define relationships here
--- Example: hasOne relationship
-- function ${modelName}:profile()
--     return self:hasOne(Profile, 'user_id', 'id')
-- end

--- Example: hasMany relationship
-- function ${modelName}:posts()
--     return self:hasMany(Post, 'user_id', 'id')
-- end

--- Example: belongsTo relationship
-- function ${modelName}:organization()
--     return self:belongsTo(Organization, 'organization_id', 'id')
-- end

--- Example: belongsToMany relationship
-- function ${modelName}:roles()
--     return self:belongsToMany(Role, 'user_roles', 'user_id', 'role_id')
-- end

--- Custom methods
function ${modelName}:customMethod()
    -- Add custom logic here
end

return ${modelName}
`;
  
  await fs.writeFile(filePath, modelContent);
  
  console.log(chalk.green(`\n✓ Model created successfully!`));
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

module.exports = makeModel;
