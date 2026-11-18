#!/bin/sh
set -eu

# Runs once on an empty PostgreSQL data volume. Read secrets through the
# environment, never psql command arguments or interpolated shell SQL.
check_password() {
    case "$2" in
        ''|*[!a-fA-F0-9]*) echo "$1 must contain hexadecimal characters only" >&2; exit 1 ;;
    esac
    if [ "${#2}" -lt 64 ]; then
        echo "$1 must contain at least 64 hexadecimal characters" >&2
        exit 1
    fi
}
check_password POSTMERE_OWNER_DB_PASSWORD "$POSTMERE_OWNER_DB_PASSWORD"
check_password POSTMERE_RUNTIME_DB_PASSWORD "$POSTMERE_RUNTIME_DB_PASSWORD"

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv owner_password POSTMERE_OWNER_DB_PASSWORD
\getenv runtime_password POSTMERE_RUNTIME_DB_PASSWORD
CREATE ROLE postmere_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_password';
CREATE ROLE postmere_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
ALTER DATABASE postmere OWNER TO postmere_owner;
REVOKE CONNECT ON DATABASE postmere FROM PUBLIC;
GRANT CONNECT ON DATABASE postmere TO postmere_owner, postmere_runtime;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO postmere_owner;
GRANT USAGE ON SCHEMA public TO postmere_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE postmere_owner IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO postmere_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE postmere_owner IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO postmere_runtime;
SQL
