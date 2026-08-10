#!/usr/bin/env node

/**
 * Obelisk CLI - Code generator for FiveM framework
 * Interactive commands for scaffolding modules, plugins, models, migrations, etc.
 */

const { program } = require('commander');
const inquirer = require('inquirer');
const fs = require('fs-extra');
const path = require('path');
const chalk = require('chalk');

// Import commands
const makeModule = require('./commands/make-module');
const makePlugin = require('./commands/make-plugin');
const makeModel = require('./commands/make-model');
const makeMigration = require('./commands/make-migration');
const makeSeeder = require('./commands/make-seeder');
const makeAction = require('./commands/make-action');
const makeInteraction = require('./commands/make-interaction');
const makePolicy = require('./commands/make-policy');
const registryGenerate = require('./commands/registry-generate');

// CLI Version
const VERSION = '1.0.0';

program
  .version(VERSION)
  .description('Obelisk Framework - Code Generator CLI');

// Make Module Command
program
  .command('make:module [name]')
  .description('Create a new module')
  .action(async (name) => {
    await makeModule(name);
  });

// Make Plugin Command
program
  .command('make:plugin [name]')
  .description('Create a new plugin')
  .action(async (name) => {
    await makePlugin(name);
  });

// Make Model Command
program
  .command('make:model [name]')
  .description('Create a new ORM model')
  .action(async (name) => {
    await makeModel(name);
  });

// Make Migration Command
program
  .command('make:migration [name]')
  .description('Create a new database migration')
  .action(async (name) => {
    await makeMigration(name);
  });

// Make Seeder Command
program
  .command('make:seeder [name]')
  .description('Create a new database seeder')
  .action(async (name) => {
    await makeSeeder(name);
  });

// Make Action Command
program
  .command('make:action [name]')
  .description('Create a new action handler')
  .action(async (name) => {
    await makeAction(name);
  });

// Make Interaction Command
program
  .command('make:interaction [name]')
  .description('Create a new interaction')
  .action(async (name) => {
    await makeInteraction(name);
  });

// Make Policy Command
program
  .command('make:policy [name]')
  .description('Create a new policy')
  .action(async (name) => {
    await makePolicy(name);
  });

// Registry Generate Command
program
  .command('registry:generate')
  .description('Scan modules/ and plugins/ and regenerate their registry.json files')
  .action(async () => {
    await registryGenerate();
  });

// Parse arguments
program.parse(process.argv);

// Show help if no command provided
if (!process.argv.slice(2).length) {
  program.outputHelp();
}

module.exports = { inquirer, fs, path, chalk };
