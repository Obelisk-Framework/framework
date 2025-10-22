# Obelisk Framework - Quick Start Checklist

## ✓ Prerequisites
- [ ] FiveM server (artifact 5848+)
- [ ] Node.js 18+ (for `npm run` commands)
- [ ] Docker & Docker Compose (optional, for MariaDB)

## ✓ Step 1: Install MySQL Library (Required)

Choose ONE:

### ghmattimysql (Recommended)
```bash
# Download from: https://github.com/GHMatti/ghmattimysql/releases
# Extract to: resources/ghmattimysql/
ls resources/ghmattimysql/   # Verify it exists
```

### oxmysql (Modern alternative)
```bash
# Download from: https://github.com/overextended/oxmysql/releases
# Extract to: resources/oxmysql/
```

### mysql-async (Legacy)
```bash
# Download from: https://github.com/brouznouf/fivem-mysql-async/releases
# Extract to: resources/mysql-async/
```

## ✓ Step 2: Start MariaDB

```bash
# Using Docker (recommended)
docker-compose up -d

# Verify it's running
docker ps | grep mariadb
```

## ✓ Step 3: Update server.cfg

Add this **before** starting your server:

```cfg
# MySQL Connector (required)
ensure ghmattimysql          # Replace with oxmysql or mysql-async if using different

# Obelisk Framework
ensure obelisk

# Database Configuration (optional - adjust to your setup)
set mysql_connection_string "mysql://obelisk:obelisk_password@mariadb:3306/fivem"
set db_debug 0
```

## ✓ Step 4: Install Dependencies

```bash
# Root dependencies
npm install

# Web dependencies
cd web
npm install
npm run build
cd ..
```

## ✓ Step 5: Start Your Server

Start FiveM server normally. Check console for:

```
[oblsk_connector] ✓ Connected using ghmattimysql
[Database] Using oblsk_connector for MySQL
[Obelisk] Running migrations...
[Obelisk] ✓ Migration completed: 2024_10_04_000001_create_actions_table
...
[Obelisk] FRAMEWORK - READY
```

## ✓ Verify Everything Works

### Test Database Connection
```lua
-- In game console or any Lua resource:
local result = exports['oblsk_connector']:executeSync("SELECT 1")
print(json.encode(result))  -- Should show [[{col_0 = 1}]]
```

### Test CLI Generators
```bash
npm run make:model User
npm run make:action TestAction
npm run make:migration create_test_table
```

## ✓ Troubleshooting

### "No MySQL connector found"
- [ ] Verify MySQL library is in `resources/` directory
- [ ] Check `server.cfg` has `ensure ghmattimysql` BEFORE `ensure obelisk`
- [ ] Check MySQL library console output for errors

### "Connection refused"
- [ ] Check MariaDB is running: `docker ps`
- [ ] Check credentials match docker-compose.yml
- [ ] Check mysql_connection_string is correct

### "Access denied for user 'obelisk'"
- [ ] Check password in docker-compose.yml matches mysql_connection_string
- [ ] Check MariaDB user exists

### Build fails
```bash
cd web
rm -rf node_modules package-lock.json
npm install --force
npm run build
```

## ✓ Next Steps

1. **Create your first module:**
   ```bash
   npm run make:module MyModule
   ```

2. **Create a database model:**
   ```bash
   npm run make:model User
   ```

3. **Create migrations:**
   ```bash
   npm run make:migration create_users_table
   ```

4. **Create actions:**
   ```bash
   npm run make:action MyAction
   ```

## ✓ Documentation

- See `AGENTS.md` for development guidelines
- See `SETUP_MYSQL.md` for detailed MySQL setup
- See `README.md` for framework overview

## ✓ Support

Common issues? Check:
1. `MYSQL_CONNECTOR_SETUP.txt` - MySQL connector setup
2. `resources/oblsk_connector/INSTALL.txt` - Connector details
3. Server console output for specific errors
4. MySQL library documentation (ghmattimysql, oxmysql, etc.)

---

**Done?** You should now have a fully functional Obelisk server with MySQL database!
