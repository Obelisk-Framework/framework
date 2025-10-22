╔════════════════════════════════════════════════════════════════╗
║          OBELISK FRAMEWORK - READ THIS FIRST                   ║
╚════════════════════════════════════════════════════════════════╝

Welcome to Obelisk Framework!

This is a modern FiveM framework built with Lua, Vue 3, and MariaDB.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

IMPORTANT: DATABASE SETUP REQUIRED

Obelisk requires a MySQL database. It won't work without it.

Follow this guide: QUICK_START.md

TL;DR:
1. Download ghmattimysql from GitHub
2. Extract to resources/ghmattimysql/
3. Add "ensure ghmattimysql" to server.cfg BEFORE obelisk
4. Run: docker-compose up -d
5. Start your server

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DOCUMENTATION

Start Here:
  → QUICK_START.md ..................... Complete setup checklist

For Developers:
  → AGENTS.md .......................... Development guidelines
  → README.md .......................... Framework overview

MySQL Setup:
  → SETUP_MYSQL.md ..................... Detailed MySQL guide
  → MYSQL_CONNECTOR_SETUP.txt .......... MySQL troubleshooting
  → resources/oblsk_connector/ ......... Connector documentation

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

QUICK COMMANDS

npm run make:module <Name>      ... Create a new module
npm run make:plugin <Name>      ... Create a new plugin  
npm run make:model <Name>       ... Create a database model
npm run make:migration <Name>   ... Create a migration
npm run make:action <Name>      ... Create an action handler
npm run make:policy <Name>      ... Create a policy

cd web && npm run build         ... Build Vue 3 frontend
docker-compose up -d            ... Start MariaDB

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PROJECT STRUCTURE

core/server/                  ... Backend logic
  ├── ORM/                    ... Database models
  ├── Services/               ... Business logic
  ├── Policies/               ... Authorization
  └── database/               ... Migrations & seeders

core/client/                  ... Client-side code
  ├── Services/               ... Client services
  └── actions/                ... Action handlers

web/                          ... Vue 3 frontend
  ├── src/components/         ... Vue components
  ├── src/composables/        ... Vue composables
  └── src/pages/              ... Page components

modules/                      ... Core feature modules
plugins/                      ... Plugin features
cli/                          ... Code generators

resources/oblsk_connector/    ... MySQL connector

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GETTING STARTED

Step 1: Read QUICK_START.md
Step 2: Install MySQL library (ghmattimysql recommended)
Step 3: Update server.cfg
Step 4: Start server
Step 5: Check console for "[Obelisk] FRAMEWORK - READY"

Having issues? See QUICK_START.md § Troubleshooting

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Support

GitHub Issues: [Create an issue]
Discord: [Join our server]
Documentation: [Read the docs]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Happy Coding! 🚀

MIT License - See LICENSE file for details
