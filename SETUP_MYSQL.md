# MySQL Setup Guide for Obelisk

FiveM doesn't have native MySQL in Lua, so you need an external MySQL library. Here's how to set it up:

## Quick Setup (Recommended)

### 1. Install ghmattimysql

Download the latest release: https://github.com/GHMatti/ghmattimysql/releases

Extract it to your resources folder:
```
resources/
├── ghmattimysql/
├── obelisk/
└── ...
```

### 2. Update server.cfg

Add this to your `server.cfg` **before** starting obelisk:

```cfg
# MySQL Setup
ensure ghmattimysql
ensure obelisk

# Database Configuration (optional, defaults shown)
set mysql_connection_string "mysql://obelisk:obelisk_password@mariadb:3306/fivem"
set db_debug 0
```

### 3. Start MariaDB (if using Docker)

```bash
docker-compose up -d
```

### 4. Start your server

```bash
# Linux/Mac
./run.sh

# Windows
run.bat
```

## Verification

Check your server console for these messages:

```
[oblsk_connector] ✓ Connected using ghmattimysql
[oblsk_connector] Config: obelisk@mariadb:3306/fivem
[Database] Using oblsk_connector for MySQL
[Obelisk] Running migrations...
```

If you see "No MySQL connector found", go back to step 1.

## Alternative MySQL Libraries

### oxmysql (Modern)
https://github.com/overextended/oxmysql/releases

```cfg
ensure oxmysql
ensure obelisk
```

### mysql-async (Legacy)
https://github.com/brouznouf/fivem-mysql-async/releases

```cfg
ensure mysql-async
ensure obelisk
```

## Troubleshooting

### "No MySQL connector found" error
- Check that ghmattimysql is in your resources folder
- Verify it's listed in server.cfg **before** obelisk
- Check MySQL library console output for connection errors

### "Connection refused" error
- Check MariaDB is running: `docker ps`
- Check credentials in mysql_connection_string
- Check MariaDB port is 3306

### "Access denied" error
- Check MariaDB user/password
- Default: user=`obelisk`, password=`obelisk_password`
- Update docker-compose.yml if needed

## Docker MariaDB Setup

If using Docker Compose:

1. Ensure Docker is running
2. Run: `docker-compose up -d`
3. Verify: `docker ps`

The default credentials are:
- User: `obelisk`
- Password: `obelisk_password`
- Database: `fivem`
- Host: `mariadb` (or `localhost` from host machine)
- Port: `3306`

Change these in `docker-compose.yml` before first start.
