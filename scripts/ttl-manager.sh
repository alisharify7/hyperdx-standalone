#!/usr/bin/env bash
# HyperDX / ClickStack ClickHouse TTL manager
#
# Defaults target the all-in-one Docker Compose service/container from this setup:
#   container: hyperdx
#   database:  default
#
# Supported connection modes:
#   auto   - Docker exec first, then HTTP, then native clickhouse-client
#   docker - run clickhouse-client inside CH_CONTAINER
#   http   - use ClickHouse HTTP interface through CH_HTTP_URL
#   native - use a local clickhouse-client through CH_HOST:CH_PORT

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"

# -----------------------------------------------------------------------------
# Configuration: override any of these with environment variables.
# -----------------------------------------------------------------------------
CH_MODE="${CH_MODE:-auto}"                       # auto|docker|http|native
CH_CONTAINER="${CH_CONTAINER:-hyperdx}"
CH_DATABASE="${CH_DATABASE:-default}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"

CH_HTTP_URL="${CH_HTTP_URL:-http://127.0.0.1:8123}"
CH_HOST="${CH_HOST:-127.0.0.1}"
CH_PORT="${CH_PORT:-9000}"
CH_SECURE="${CH_SECURE:-0}"                     # 1 enables TLS for native mode
CH_CONNECT_TIMEOUT="${CH_CONNECT_TIMEOUT:-5}"
CH_QUERY_TIMEOUT="${CH_QUERY_TIMEOUT:-300}"

BACKUP_DIR="${BACKUP_DIR:-./hyperdx-ttl-backups}"

ACTIVE_MODE=""
DOCKER_CLIENT_STYLE=""
declare -a TABLES=()
declare -a SELECTED_TABLES=()

# -----------------------------------------------------------------------------
# Terminal helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_BOLD=""
    C_RESET=""
fi

info()  { printf '%s[INFO]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

pause_menu() {
    local unused
    printf '\n'
    read -r -p "Press Enter to return to the menu..." unused || true
}

print_rule() {
    printf '%s\n' '-------------------------------------------------------------------------------'
}

# -----------------------------------------------------------------------------
# Input and SQL safety helpers
# -----------------------------------------------------------------------------
valid_identifier() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

quote_identifier() {
    valid_identifier "$1" || return 1
    printf '`%s`' "$1"
}

sql_literal() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

validate_config() {
    (( BASH_VERSINFO[0] >= 4 )) || die "Bash 4 or newer is required."

    CH_MODE=${CH_MODE,,}
    case "$CH_MODE" in
        auto|docker|http|native) ;;
        *) die "CH_MODE must be one of: auto, docker, http, native." ;;
    esac

    valid_identifier "$CH_DATABASE" || \
        die "Unsafe CH_DATABASE value: '$CH_DATABASE'. Use letters, numbers, and underscores only."

    [[ "$CH_PORT" =~ ^[0-9]+$ ]] || die "CH_PORT must be numeric."
    [[ "$CH_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "CH_CONNECT_TIMEOUT must be numeric."
    [[ "$CH_QUERY_TIMEOUT" =~ ^[0-9]+$ ]] || die "CH_QUERY_TIMEOUT must be numeric."
    [[ "$CH_SECURE" == "0" || "$CH_SECURE" == "1" ]] || die "CH_SECURE must be 0 or 1."

    if [[ "$CH_USER" == *$'\n'* || "$CH_USER" == *$'\r'* || \
          "$CH_PASSWORD" == *$'\n'* || "$CH_PASSWORD" == *$'\r'* ]]; then
        die "Credentials must not contain newline characters."
    fi
}

# -----------------------------------------------------------------------------
# ClickHouse connection layer
# -----------------------------------------------------------------------------
configure_docker_mode() {
    command -v docker >/dev/null 2>&1 || return 1

    local running
    running=$(docker inspect -f '{{.State.Running}}' "$CH_CONTAINER" 2>/dev/null) || return 1
    [[ "$running" == "true" ]] || return 1

    if docker exec "$CH_CONTAINER" clickhouse-client --version >/dev/null 2>&1; then
        DOCKER_CLIENT_STYLE="clickhouse-client"
        return 0
    fi

    if docker exec "$CH_CONTAINER" clickhouse client --version >/dev/null 2>&1; then
        DOCKER_CLIENT_STYLE="clickhouse-client-subcommand"
        return 0
    fi

    return 1
}

configure_http_mode() {
    command -v curl >/dev/null 2>&1 || return 1
    [[ "$CH_HTTP_URL" =~ ^https?:// ]] || return 1
    return 0
}

configure_native_mode() {
    command -v clickhouse-client >/dev/null 2>&1 || return 1
    return 0
}

ch_query() {
    local sql="$1"
    local format="${2:-TSVRaw}"

    case "$ACTIVE_MODE" in
        docker)
            # Pass credentials to docker exec by variable name, not as literal CLI values.
            # This keeps the password out of the Docker CLI argument list.
            (
                export CLICKHOUSE_USER="$CH_USER"
                export CLICKHOUSE_PASSWORD="$CH_PASSWORD"
                export CLICKHOUSE_HOST="127.0.0.1"

                if [[ "$DOCKER_CLIENT_STYLE" == "clickhouse-client" ]]; then
                    docker exec -i \
                        -e CLICKHOUSE_USER \
                        -e CLICKHOUSE_PASSWORD \
                        -e CLICKHOUSE_HOST \
                        "$CH_CONTAINER" \
                        clickhouse-client \
                        --multiquery \
                        --database "$CH_DATABASE" \
                        --format "$format" \
                        --query "$sql"
                else
                    docker exec -i \
                        -e CLICKHOUSE_USER \
                        -e CLICKHOUSE_PASSWORD \
                        -e CLICKHOUSE_HOST \
                        "$CH_CONTAINER" \
                        clickhouse client \
                        --multiquery \
                        --database "$CH_DATABASE" \
                        --format "$format" \
                        --query "$sql"
                fi
            )
            ;;

        http)
            local fail_option="--fail"
            if curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
                fail_option="--fail-with-body"
            fi

            curl \
                --silent \
                --show-error \
                "$fail_option" \
                --connect-timeout "$CH_CONNECT_TIMEOUT" \
                --max-time "$CH_QUERY_TIMEOUT" \
                --user "${CH_USER}:${CH_PASSWORD}" \
                --header "X-ClickHouse-Database: ${CH_DATABASE}" \
                --data-binary "$sql" \
                "${CH_HTTP_URL%/}/?default_format=${format}"
            ;;

        native)
            local -a secure_arg=()
            [[ "$CH_SECURE" == "1" ]] && secure_arg+=(--secure)

            CLICKHOUSE_USER="$CH_USER" \
            CLICKHOUSE_PASSWORD="$CH_PASSWORD" \
            CLICKHOUSE_HOST="$CH_HOST" \
                clickhouse-client \
                    --port "$CH_PORT" \
                    "${secure_arg[@]}" \
                    --multiquery \
                    --database "$CH_DATABASE" \
                    --format "$format" \
                    --query "$sql"
            ;;

        *)
            error "No active ClickHouse connection mode."
            return 1
            ;;
    esac
}

probe_active_mode() {
    local result
    result=$(ch_query "SELECT 1" TSVRaw 2>/dev/null) || return 1
    [[ "$result" == "1" ]]
}

detect_connection() {
    local requested="$CH_MODE"

    if [[ "$requested" == "docker" ]]; then
        configure_docker_mode || \
            die "Docker mode failed. Is container '$CH_CONTAINER' running, and does it contain clickhouse-client?"
        ACTIVE_MODE="docker"
        probe_active_mode || die "Could not authenticate to ClickHouse through container '$CH_CONTAINER'."
        return 0
    fi

    if [[ "$requested" == "http" ]]; then
        configure_http_mode || die "HTTP mode requires curl and a valid CH_HTTP_URL."
        ACTIVE_MODE="http"
        probe_active_mode || die "Could not connect to ClickHouse at '$CH_HTTP_URL'."
        return 0
    fi

    if [[ "$requested" == "native" ]]; then
        configure_native_mode || die "Native mode requires clickhouse-client on this host."
        ACTIVE_MODE="native"
        probe_active_mode || die "Could not connect to ClickHouse at '$CH_HOST:$CH_PORT'."
        return 0
    fi

    # Auto mode: prefer docker exec for the all-in-one container.
    if configure_docker_mode; then
        ACTIVE_MODE="docker"
        if probe_active_mode; then
            return 0
        fi
        warn "Docker connection probe failed; trying another connection method."
    fi

    if configure_http_mode; then
        ACTIVE_MODE="http"
        if probe_active_mode; then
            return 0
        fi
        warn "HTTP connection probe failed; trying native clickhouse-client."
    fi

    if configure_native_mode; then
        ACTIVE_MODE="native"
        if probe_active_mode; then
            return 0
        fi
    fi

    die "Unable to connect to ClickHouse using Docker, HTTP, or native client mode."
}

test_connection() {
    local result version user database
    if ! result=$(ch_query "SELECT version(), currentUser(), currentDatabase()" TSVRaw); then
        error "ClickHouse connection test failed."
        return 1
    fi

    IFS=$'\t' read -r version user database <<< "$result"
    ok "Connected to ClickHouse $version as '$user'; current database: '$database'; mode: '$ACTIVE_MODE'."
}

# -----------------------------------------------------------------------------
# HyperDX table discovery and schema helpers
# -----------------------------------------------------------------------------
load_hyperdx_tables() {
    local db output
    db=$(sql_literal "$CH_DATABASE")

    if ! output=$(ch_query "
        SELECT name
        FROM system.tables
        WHERE database = ${db}
          AND position(engine, 'MergeTree') > 0
          AND name IN
          (
              'otel_logs',
              'otel_traces',
              'otel_metrics_gauge',
              'otel_metrics_sum',
              'otel_metrics_histogram',
              'otel_metrics_exponential_histogram',
              'otel_metrics_summary',
              'hyperdx_sessions'
          )
        ORDER BY name
    " TSVRaw); then
        error "Could not query system.tables."
        return 1
    fi

    TABLES=()
    while IFS= read -r table; do
        [[ -n "$table" ]] || continue
        if valid_identifier "$table"; then
            TABLES+=("$table")
        else
            warn "Ignoring table with an unsafe identifier: '$table'."
        fi
    done <<< "$output"

    if (( ${#TABLES[@]} == 0 )); then
        warn "No standard HyperDX/ClickStack MergeTree tables were found in database '$CH_DATABASE'."
        warn "Make sure telemetry has created the tables, or set CH_DATABASE to the collector database."
        return 1
    fi

    return 0
}

time_column_for_table() {
    local table="$1" db_lit table_lit
    db_lit=$(sql_literal "$CH_DATABASE")
    table_lit=$(sql_literal "$table")

    ch_query "
        SELECT name
        FROM system.columns
        WHERE database = ${db_lit}
          AND table = ${table_lit}
          AND name IN ('TimeUnix', 'TimestampTime', 'Timestamp')
        ORDER BY indexOf(['TimeUnix', 'TimestampTime', 'Timestamp'], name)
        LIMIT 1
    " TSVRaw
}

ttl_base_for_column() {
    case "$1" in
        TimeUnix)      printf 'toDateTime(`TimeUnix`)' ;;
        TimestampTime) printf '`TimestampTime`' ;;
        Timestamp)     printf 'toDateTime(`Timestamp`)' ;;
        *) return 1 ;;
    esac
}

qualified_table() {
    local database table
    database=$(quote_identifier "$CH_DATABASE") || return 1
    table=$(quote_identifier "$1") || return 1
    printf '%s.%s' "$database" "$table"
}

get_table_ddl() {
    local qtable
    qtable=$(qualified_table "$1") || return 1
    ch_query "SHOW CREATE TABLE ${qtable}" TSVRaw
}

normalize_ddl() {
    local ddl="$1"

    # Handle both actual line breaks and escaped line breaks from client formats.
    ddl=${ddl//\\n/ }
    ddl=${ddl//\\r/ }
    ddl=${ddl//\\t/ }
    ddl=${ddl//$'\n'/ }
    ddl=${ddl//$'\r'/ }
    ddl=${ddl//$'\t'/ }

    printf '%s\n' "$ddl" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

ttl_from_ddl() {
    local flat after ttl
    flat=$(normalize_ddl "$1")

    # Column-level TTL clauses are before ENGINE. The table-level TTL is after ENGINE.
    [[ "$flat" == *" ENGINE "* ]] || return 1
    after=${flat#* ENGINE }
    [[ "$after" == *" TTL "* ]] || return 1
    ttl=${after#* TTL }

    if [[ "$ttl" == *" SETTINGS "* ]]; then
        ttl=${ttl%% SETTINGS *}
    fi
    if [[ "$ttl" == *" COMMENT "* ]]; then
        ttl=${ttl%% COMMENT *}
    fi

    ttl=${ttl%;}
    [[ -n "$ttl" ]] || return 1
    printf '%s' "$ttl"
}

ttl_only_drop_parts_from_ddl() {
    local flat
    flat=$(normalize_ddl "$1")

    if [[ "$flat" =~ ttl_only_drop_parts[[:space:]]*=[[:space:]]*([01]) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'unset'
    fi
}

canonical_expression() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[`[:space:];]//g'
}

get_part_stats() {
    local table="$1" db_lit table_lit
    db_lit=$(sql_literal "$CH_DATABASE")
    table_lit=$(sql_literal "$table")

    ch_query "
        SELECT
            count() AS active_parts,
            sum(rows) AS rows,
            formatReadableSize(sum(bytes_on_disk)) AS size,
            countIf(delete_ttl_info_max > toDateTime(0)) AS parts_with_ttl_metadata,
            countIf(delete_ttl_info_max > toDateTime(0) AND delete_ttl_info_max <= now()) AS expired_parts,
            if(
                parts_with_ttl_metadata = 0,
                'n/a',
                toString(minIf(delete_ttl_info_min, delete_ttl_info_min > toDateTime(0)))
            ) AS earliest_expiration,
            if(
                parts_with_ttl_metadata = 0,
                'n/a',
                toString(max(delete_ttl_info_max))
            ) AS latest_expiration
        FROM system.parts
        WHERE active
          AND database = ${db_lit}
          AND table = ${table_lit}
    " TSVRaw
}

# -----------------------------------------------------------------------------
# Read-only operations: list, get, verify
# -----------------------------------------------------------------------------
list_hyperdx_tables() {
    load_hyperdx_tables || return 1

    printf '\n%sHyperDX/ClickStack tables in %s%s\n' "$C_BOLD" "$CH_DATABASE" "$C_RESET"
    print_rule

    local table column
    for table in "${TABLES[@]}"; do
        column=$(time_column_for_table "$table" 2>/dev/null || true)
        [[ -n "$column" ]] || column="unsupported/missing"
        printf '  %-44s time column: %s\n' "${CH_DATABASE}.${table}" "$column"
    done
}

show_current_ttls() {
    load_hyperdx_tables || return 1

    printf '\n%sCurrent HyperDX TTL configuration%s\n' "$C_BOLD" "$C_RESET"
    print_rule

    local table column ddl ttl drop_setting stats
    local parts rows size ttl_parts expired earliest latest

    for table in "${TABLES[@]}"; do
        column=$(time_column_for_table "$table" 2>/dev/null || true)

        if ! ddl=$(get_table_ddl "$table"); then
            error "Could not read DDL for ${CH_DATABASE}.${table}."
            continue
        fi

        ttl=$(ttl_from_ddl "$ddl" 2>/dev/null || true)
        drop_setting=$(ttl_only_drop_parts_from_ddl "$ddl")

        stats=$(get_part_stats "$table" 2>/dev/null || true)
        if [[ -n "$stats" ]]; then
            IFS=$'\t' read -r parts rows size ttl_parts expired earliest latest <<< "$stats"
        else
            parts="?"; rows="?"; size="?"; ttl_parts="?"; expired="?"; earliest="?"; latest="?"
        fi

        printf '\n%s%s.%s%s\n' "$C_BOLD" "$CH_DATABASE" "$table" "$C_RESET"
        printf '  Time column               : %s\n' "${column:-not detected}"
        printf '  Table TTL                 : %s\n' "${ttl:-NOT SET}"
        printf '  ttl_only_drop_parts       : %s\n' "$drop_setting"
        printf '  Active parts / rows / size: %s / %s / %s\n' "$parts" "$rows" "$size"
        printf '  Parts with TTL metadata   : %s\n' "$ttl_parts"
        printf '  Part expiration window    : %s  ->  %s\n' "$earliest" "$latest"
        printf '  Expired parts still active: %s\n' "$expired"
    done
}

verify_ttls() {
    load_hyperdx_tables || return 1

    printf '\n%sTTL verification%s\n' "$C_BOLD" "$C_RESET"
    print_rule

    local pass=0 warnings=0 failures=0
    local table column ddl ttl drop_setting stats
    local parts rows size ttl_parts expired earliest latest
    local ttl_canon column_canon

    for table in "${TABLES[@]}"; do
        printf '\n%s.%s\n' "$CH_DATABASE" "$table"

        column=$(time_column_for_table "$table" 2>/dev/null || true)
        if [[ -z "$column" ]]; then
            error "No supported timestamp column was found."
            ((failures++))
            continue
        fi
        ok "Timestamp column detected: $column"

        if ! ddl=$(get_table_ddl "$table"); then
            error "Unable to read SHOW CREATE TABLE."
            ((failures++))
            continue
        fi

        ttl=$(ttl_from_ddl "$ddl" 2>/dev/null || true)
        if [[ -z "$ttl" ]]; then
            error "No table-level TTL exists in the table definition."
            ((failures++))
            continue
        fi
        ok "Table-level TTL exists: $ttl"

        ttl_canon=$(canonical_expression "$ttl")
        column_canon=$(canonical_expression "$column")
        if [[ "$ttl_canon" == *"$column_canon"* ]]; then
            ok "TTL references the detected timestamp column."
        else
            warn "TTL exists but does not appear to reference '$column': $ttl"
            ((warnings++))
        fi

        drop_setting=$(ttl_only_drop_parts_from_ddl "$ddl")
        if [[ "$drop_setting" == "1" ]]; then
            ok "ttl_only_drop_parts=1 is enabled."
        else
            warn "ttl_only_drop_parts is '$drop_setting', not 1."
            ((warnings++))
        fi

        stats=$(get_part_stats "$table" 2>/dev/null || true)
        if [[ -z "$stats" ]]; then
            warn "Could not inspect system.parts."
            ((warnings++))
            continue
        fi

        IFS=$'\t' read -r parts rows size ttl_parts expired earliest latest <<< "$stats"
        if [[ "$parts" == "0" ]]; then
            info "The table has no active data parts yet; part-level verification is not applicable."
        elif [[ "$ttl_parts" == "$parts" ]]; then
            ok "All $parts active parts contain DELETE TTL metadata."
        else
            warn "$ttl_parts of $parts active parts contain DELETE TTL metadata."
            warn "Existing parts may need a normal merge or MATERIALIZE TTL."
            ((warnings++))
        fi

        if [[ "$expired" =~ ^[0-9]+$ ]] && (( expired > 0 )); then
            warn "$expired active parts have reached their TTL expiration time and await cleanup."
            ((warnings++))
        fi

        ((pass++))
    done

    printf '\n'
    print_rule
    printf 'Tables with a TTL definition: %d\n' "$pass"
    printf 'Warnings                    : %d\n' "$warnings"
    printf 'Failures                    : %d\n' "$failures"

    (( failures == 0 ))
}

# -----------------------------------------------------------------------------
# Selection and retention prompts
# -----------------------------------------------------------------------------
choose_one_table() {
    load_hyperdx_tables || return 1

    printf '\nSelect a table:\n'
    local i choice index
    for i in "${!TABLES[@]}"; do
        printf '  %d) %s.%s\n' "$((i + 1))" "$CH_DATABASE" "${TABLES[$i]}"
    done
    printf '  0) Cancel\n'

    read -r -p "Choice: " choice || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid selection."; return 1; }
    [[ "$choice" != "0" ]] || return 1

    index=$((10#$choice - 1))
    (( index >= 0 && index < ${#TABLES[@]} )) || { warn "Invalid selection."; return 1; }

    SELECTED_TABLES=("${TABLES[$index]}")
}

choose_retention() {
    local amount unit_choice

    while true; do
        read -r -p "Retention amount (positive integer): " amount || return 1
        if [[ "$amount" =~ ^[1-9][0-9]*$ ]]; then
            break
        fi
        warn "Enter a positive whole number, for example 7 or 30."
    done

    printf '\nRetention unit:\n'
    printf '  1) Hours\n'
    printf '  2) Days\n'
    printf '  3) Weeks\n'
    printf '  4) Months\n'
    read -r -p "Choice [2]: " unit_choice || return 1
    unit_choice=${unit_choice:-2}

    case "$unit_choice" in
        1)
            RETENTION_FUNCTION="toIntervalHour"
            RETENTION_UNIT_LABEL="hour(s)"
            warn "ClickStack tables are partitioned by day; whole-part deletion may make hourly retention approximate."
            ;;
        2)
            RETENTION_FUNCTION="toIntervalDay"
            RETENTION_UNIT_LABEL="day(s)"
            ;;
        3)
            RETENTION_FUNCTION="toIntervalWeek"
            RETENTION_UNIT_LABEL="week(s)"
            ;;
        4)
            RETENTION_FUNCTION="toIntervalMonth"
            RETENTION_UNIT_LABEL="month(s)"
            ;;
        *)
            warn "Invalid unit selection."
            return 1
            ;;
    esac

    RETENTION_AMOUNT="$amount"
}

# -----------------------------------------------------------------------------
# Backup and write operations
# -----------------------------------------------------------------------------
backup_table_definitions() {
    local run_dir table ddl file
    run_dir="${BACKUP_DIR%/}/$(date -u +%Y%m%dT%H%M%SZ)"

    mkdir -p "$run_dir" || {
        error "Unable to create backup directory '$run_dir'."
        return 1
    }

    for table in "$@"; do
        if ! ddl=$(get_table_ddl "$table"); then
            error "Could not back up ${CH_DATABASE}.${table}; no changes were made."
            return 1
        fi

        file="${run_dir}/${CH_DATABASE}.${table}.sql"
        {
            printf -- '-- Captured by hyperdx-ttl-manager.sh at %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
            printf '%s;\n' "${ddl%;}"
        } > "$file" || return 1
    done

    LAST_BACKUP_DIR="$run_dir"
    return 0
}

apply_ttl_to_tables() {
    local -a targets=("$@")
    (( ${#targets[@]} > 0 )) || return 1

    choose_retention || return 1

    printf '\n%sPlanned TTL changes%s\n' "$C_BOLD" "$C_RESET"
    print_rule

    local table column base expression
    local unsupported=0
    for table in "${targets[@]}"; do
        column=$(time_column_for_table "$table" 2>/dev/null || true)
        if [[ -z "$column" ]] || ! base=$(ttl_base_for_column "$column"); then
            error "${CH_DATABASE}.${table}: no supported timestamp column; it will not be changed."
            ((unsupported++))
            continue
        fi
        expression="${base} + ${RETENTION_FUNCTION}(${RETENTION_AMOUNT})"
        printf '  %-44s TTL %s\n' "${CH_DATABASE}.${table}" "$expression"
        printf '  %-44s SETTING ttl_only_drop_parts = 1\n' ""
    done

    (( unsupported < ${#targets[@]} )) || {
        error "No selected table can be modified."
        return 1
    }

    printf '\nThis replaces any existing table-level TTL on the selected tables.\n'
    read -r -p "Type APPLY to continue: " confirmation || return 1
    [[ "$confirmation" == "APPLY" ]] || {
        info "No changes made."
        return 0
    }

    if ! backup_table_definitions "${targets[@]}"; then
        error "DDL backup failed; aborting before ALTER TABLE."
        return 1
    fi
    ok "Saved pre-change table definitions under: $LAST_BACKUP_DIR"

    local qtable ddl actual actual_canon expected_canon
    local changed=0 failed=0 setting_warnings=0

    for table in "${targets[@]}"; do
        column=$(time_column_for_table "$table" 2>/dev/null || true)
        if [[ -z "$column" ]] || ! base=$(ttl_base_for_column "$column"); then
            continue
        fi

        expression="${base} + ${RETENTION_FUNCTION}(${RETENTION_AMOUNT})"
        qtable=$(qualified_table "$table") || {
            error "Unsafe table identifier: '$table'."
            ((failed++))
            continue
        }

        info "Applying TTL to ${CH_DATABASE}.${table}..."
        if ! ch_query "ALTER TABLE ${qtable} MODIFY TTL ${expression}" TSVRaw >/dev/null; then
            error "TTL ALTER failed for ${CH_DATABASE}.${table}."
            ((failed++))
            continue
        fi

        if ! ch_query "ALTER TABLE ${qtable} MODIFY SETTING ttl_only_drop_parts = 1" TSVRaw >/dev/null; then
            warn "TTL changed, but ttl_only_drop_parts=1 could not be applied to ${CH_DATABASE}.${table}."
            ((setting_warnings++))
        fi

        if ! ddl=$(get_table_ddl "$table"); then
            error "TTL changed, but post-change verification could not read the DDL."
            ((failed++))
            continue
        fi

        actual=$(ttl_from_ddl "$ddl" 2>/dev/null || true)
        actual_canon=$(canonical_expression "$actual")
        expected_canon=$(canonical_expression "$expression")

        if [[ -n "$actual" && "$actual_canon" == "$expected_canon"* ]]; then
            ok "Verified ${CH_DATABASE}.${table}: $actual"
            ((changed++))
        else
            error "Post-change verification mismatch for ${CH_DATABASE}.${table}."
            error "Expected: $expression"
            error "Actual  : ${actual:-NOT SET}"
            ((failed++))
        fi
    done

    printf '\n'
    print_rule
    printf 'Verified table changes : %d\n' "$changed"
    printf 'Setting warnings       : %d\n' "$setting_warnings"
    printf 'Failed/verif. mismatch : %d\n' "$failed"
    printf 'Retention requested    : %s %s\n' "$RETENTION_AMOUNT" "$RETENTION_UNIT_LABEL"
    printf 'DDL backup directory   : %s\n' "$LAST_BACKUP_DIR"
    printf '\nThe TTL definition is active now. Physical deletion normally occurs during background TTL merges.\n'
    printf 'Use the MATERIALIZE menu action only when immediate cleanup is required and the load is acceptable.\n'

    (( failed == 0 ))
}

apply_ttl_all() {
    load_hyperdx_tables || return 1
    SELECTED_TABLES=("${TABLES[@]}")
    apply_ttl_to_tables "${SELECTED_TABLES[@]}"
}

apply_ttl_one() {
    choose_one_table || return 1
    apply_ttl_to_tables "${SELECTED_TABLES[@]}"
}

materialize_ttl() {
    local scope choice
    load_hyperdx_tables || return 1

    printf '\nMaterialize TTL for:\n'
    printf '  1) One table\n'
    printf '  2) All discovered HyperDX tables\n'
    printf '  0) Cancel\n'
    read -r -p "Choice: " scope || return 1

    case "$scope" in
        1) choose_one_table || return 1 ;;
        2) SELECTED_TABLES=("${TABLES[@]}") ;;
        0) return 0 ;;
        *) warn "Invalid selection."; return 1 ;;
    esac

    printf '\n%sWARNING:%s MATERIALIZE TTL can trigger substantial merges/mutations and delete expired data now.\n' \
        "$C_YELLOW" "$C_RESET"
    printf 'Selected tables:\n'
    for choice in "${SELECTED_TABLES[@]}"; do
        printf '  - %s.%s\n' "$CH_DATABASE" "$choice"
    done

    read -r -p "Type MATERIALIZE to continue: " choice || return 1
    [[ "$choice" == "MATERIALIZE" ]] || {
        info "No changes made."
        return 0
    }

    local table qtable submitted=0 failed=0
    for table in "${SELECTED_TABLES[@]}"; do
        qtable=$(qualified_table "$table") || continue
        info "Submitting MATERIALIZE TTL for ${CH_DATABASE}.${table}..."
        if ch_query "ALTER TABLE ${qtable} MATERIALIZE TTL" TSVRaw >/dev/null; then
            ok "Submitted MATERIALIZE TTL for ${CH_DATABASE}.${table}."
            ((submitted++))
        else
            error "MATERIALIZE TTL failed for ${CH_DATABASE}.${table}."
            ((failed++))
        fi
    done

    printf '\nSubmitted: %d; failed: %d\n' "$submitted" "$failed"
    printf 'Run Verify TTL again to inspect active parts and pending expiration.\n'
    (( failed == 0 ))
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
show_header() {
    printf '\n%sHyperDX / ClickStack TTL Manager%s  v%s\n' "$C_BOLD" "$C_RESET" "$SCRIPT_VERSION"
    printf 'Connection: %-7s  Database: %-16s' "$ACTIVE_MODE" "$CH_DATABASE"
    if [[ "$ACTIVE_MODE" == "docker" ]]; then
        printf '  Container: %s' "$CH_CONTAINER"
    elif [[ "$ACTIVE_MODE" == "http" ]]; then
        printf '  Endpoint: %s' "$CH_HTTP_URL"
    else
        printf '  Endpoint: %s:%s' "$CH_HOST" "$CH_PORT"
    fi
    printf '\n'
    print_rule
}

main_menu() {
    local choice

    while true; do
        show_header
        cat <<'MENU'
  1) Test ClickHouse connection
  2) List discovered HyperDX tables
  3) Get current TTL configuration
  4) Apply/change TTL on all HyperDX tables
  5) Apply/change TTL on one HyperDX table
  6) Verify TTL definitions and part metadata
  7) Force MATERIALIZE TTL (potentially expensive)
  0) Exit
MENU
        printf '\n'
        read -r -p "Select an option: " choice || { printf '\n'; return 0; }

        case "$choice" in
            1) test_connection || true; pause_menu ;;
            2) list_hyperdx_tables || true; pause_menu ;;
            3) show_current_ttls || true; pause_menu ;;
            4) apply_ttl_all || true; pause_menu ;;
            5) apply_ttl_one || true; pause_menu ;;
            6) verify_ttls || true; pause_menu ;;
            7) materialize_ttl || true; pause_menu ;;
            0) printf 'Bye.\n'; return 0 ;;
            *) warn "Unknown menu option: '$choice'."; pause_menu ;;
        esac
    done
}

main() {
    validate_config
    detect_connection
    test_connection || die "Initial connection test failed."
    main_menu
}

main "$@"
