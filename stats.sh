#!/bin/bash

# SQLite Analytics Query Script
# Query visitor analytics data with composable flags

set -e

DB_PATH="./understanding.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
METRIC=""
PERIOD="week"
GROUP=""
BY=""
LIMIT=20
PER_LIMIT=""
URL_FILTER=""
REFERRER_FILTER=""
INCLUDE_BOTS=false
STRICT_BOTS=false
CHART=false
BAR_WIDTH=30

# SQL expression to normalize URLs by stripping fragments
# e.g., /blog/article#section -> /blog/article
URL_EXPR="substr(url, 1, instr(url || '#', '#') - 1)"

# Sanitize input for SQL (escape single quotes by doubling them)
sanitize_sql() {
    local q="'"
    printf '%s' "${1//$q/$q$q}"
}

usage() {
    cat << 'EOF'
Usage: ./stats.sh [options]

Options:
  -m, --metric <type>     What to measure (required)
  -p, --period <range>    Time period (default: week)
  -g, --group <interval>  Group results by time interval
  --by <dimension>        Add secondary dimension (referrer, page, day)
  -l, --limit <n>         Limit results (default: 20)
  -n, --per <n>           Limit items per group (requires --by)
  --url <pattern>         Filter by URL substring
  --referrer <pattern>    Filter by referrer substring
  --include-bots          Include bot traffic (excluded by default)
  --strict-bots           Also filter US cloud/VPS provider IPs (DigitalOcean, Linode, Vultr)
  -c, --chart             Show horizontal bar chart
  -h, --help              Show help

Metrics (-m):
  visitors    Unique IP count
  pageviews   Total page view count
  pages       Top pages by unique visitors
  referrers   Top referrers by unique visitors
  trending    Pages with recent traffic spike vs baseline

Periods (-p):
  today       Current day
  yesterday   Previous day
  week        Last 7 days (default)
  month       Last 30 days
  year        Last 365 days
  all         All time

Grouping (-g):
  hour        Group by hour
  day         Group by day
  week        Group by week (shows days + daily_avg, excludes partial days)
  month       Group by month (shows days + daily_avg, excludes partial days)
  (none)      Aggregate totals

Breakdown (--by):
  referrer    Break down by referrer source
  page        Break down by page URL
  day         Break down by day

Examples:
  # Daily unique visitors for last week
  ./stats.sh -m visitors -p week -g day

  # Top 10 pages this month
  ./stats.sh -m pages -p month -l 10

  # Top referrers this week
  ./stats.sh -m referrers -p week

  # Top pages broken down by referrer
  ./stats.sh -m pages -p month --by referrer

  # Daily visitors broken down by referrer source
  ./stats.sh -m visitors -p week -g day --by referrer

  # Traffic to a specific article
  ./stats.sh -m visitors -p month -g day --url "/blog/my-article"

  # What pages does Google traffic visit?
  ./stats.sh -m pages -p month --referrer "google"

  # Trending pages (recent spike vs baseline)
  ./stats.sh -m trending

  # Weekly summary with daily averages (excludes partial days around outages)
  ./stats.sh -m visitors -g week -p month

  # Daily visitors with bar chart
  ./stats.sh -m visitors -g day --chart

  # Daily visitors, top 5 referrers per day, for 7 days
  ./stats.sh -m visitors -g day --by referrer -l 7 -n 5
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--metric)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: -m requires a value"; exit 1; }
            METRIC="$2"
            shift 2
            ;;
        -p|--period)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: -p requires a value"; exit 1; }
            PERIOD="$2"
            shift 2
            ;;
        -g|--group)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: -g requires a value"; exit 1; }
            GROUP="$2"
            shift 2
            ;;
        --by)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: --by requires a value"; exit 1; }
            BY="$2"
            shift 2
            ;;
        -l|--limit)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: -l requires a value"; exit 1; }
            LIMIT="$2"
            shift 2
            ;;
        -n|--per)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: -n/--per requires a value"; exit 1; }
            PER_LIMIT="$2"
            shift 2
            ;;
        --url)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: --url requires a value"; exit 1; }
            URL_FILTER="$2"
            shift 2
            ;;
        --referrer)
            [[ -z "$2" || "$2" == -* ]] && { echo "Error: --referrer requires a value"; exit 1; }
            REFERRER_FILTER="$2"
            shift 2
            ;;
        --include-bots)
            INCLUDE_BOTS=true
            shift
            ;;
        --strict-bots)
            STRICT_BOTS=true
            shift
            ;;
        -c|--chart)
            CHART=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate metric
if [[ -z "$METRIC" ]]; then
    echo "Error: -m/--metric is required"
    echo ""
    usage
    exit 1
fi

# Validate limit is numeric
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "Error: -l/--limit must be a number"
    exit 1
fi

# Validate per-limit
if [[ -n "$PER_LIMIT" ]]; then
    if ! [[ "$PER_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: -n/--per must be a number"
        exit 1
    fi
    if [[ -z "$BY" ]]; then
        echo "Error: -n/--per requires --by"
        exit 1
    fi
fi

# Sanitize user inputs for SQL
URL_FILTER=$(sanitize_sql "$URL_FILTER")
REFERRER_FILTER=$(sanitize_sql "$REFERRER_FILTER")

# Check database exists
if [[ ! -f "$SCRIPT_DIR/$DB_PATH" ]] && [[ ! -f "$DB_PATH" ]]; then
    echo "Error: Database not found at $DB_PATH"
    exit 1
fi

# Use script directory for DB path if running from elsewhere
if [[ -f "$SCRIPT_DIR/$DB_PATH" ]]; then
    DB_PATH="$SCRIPT_DIR/$DB_PATH"
fi

# Check if grouping needs daily averages (week/month/year but not day/hour)
needs_daily_avg() {
    [[ "$GROUP" == "week" || "$GROUP" == "month" || "$GROUP" == "year" ]]
}

# Build period filter
# When grouping by week/month/year, exclude today and the boundary day to avoid partial data
get_period_filter() {
    # Check if we should exclude partial boundary days
    local exclude_boundaries=false
    if needs_daily_avg; then
        exclude_boundaries=true
    fi

    case $PERIOD in
        today)
            echo "date(timestamp) = date('now')"
            ;;
        yesterday)
            echo "date(timestamp) = date('now', '-1 day')"
            ;;
        week)
            if $exclude_boundaries; then
                # Exclude today and 7 days ago (both potentially partial)
                echo "date(timestamp) > date('now', '-7 days') AND date(timestamp) < date('now')"
            else
                echo "timestamp >= datetime('now', '-7 days')"
            fi
            ;;
        month)
            if $exclude_boundaries; then
                echo "date(timestamp) > date('now', '-30 days') AND date(timestamp) < date('now')"
            else
                echo "timestamp >= datetime('now', '-30 days')"
            fi
            ;;
        year)
            if $exclude_boundaries; then
                echo "date(timestamp) > date('now', '-365 days') AND date(timestamp) < date('now')"
            else
                echo "timestamp >= datetime('now', '-365 days')"
            fi
            ;;
        all)
            if $exclude_boundaries; then
                # Exclude just today for 'all' period
                echo "date(timestamp) < date('now')"
            else
                echo "1=1"
            fi
            ;;
        *)
            if $exclude_boundaries; then
                echo "date(timestamp) > date('now', '-7 days') AND date(timestamp) < date('now')"
            else
                echo "timestamp >= datetime('now', '-7 days')"
            fi
            ;;
    esac
}

# Build group by clause
get_group_select() {
    case $GROUP in
        hour)
            echo "strftime('%Y-%m-%d %H:00', timestamp) as period"
            ;;
        day)
            echo "date(timestamp) as period"
            ;;
        week)
            echo "strftime('%Y-W%W', timestamp) as period"
            ;;
        month)
            echo "strftime('%Y-%m', timestamp) as period"
            ;;
        *)
            echo ""
            ;;
    esac
}

get_group_by() {
    case $GROUP in
        hour)
            echo "strftime('%Y-%m-%d %H:00', timestamp)"
            ;;
        day)
            echo "date(timestamp)"
            ;;
        week)
            echo "strftime('%Y-W%W', timestamp)"
            ;;
        month)
            echo "strftime('%Y-%m', timestamp)"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Build bot filter
get_bot_filter() {
    if [[ "$INCLUDE_BOTS" == "false" ]]; then
        local filter="AND (
        user_agent NOT LIKE '%bot%' AND
        user_agent NOT LIKE '%Bot%' AND
        user_agent NOT LIKE '%crawler%' AND
        user_agent NOT LIKE '%spider%' AND
        user_agent NOT LIKE '%Googlebot%' AND
        user_agent NOT LIKE '%Bingbot%' AND
        user_agent NOT LIKE '%baiduspider%' AND
        user_agent NOT LIKE '%yandex%' AND
        user_agent NOT LIKE '%DuckDuckBot%' AND
        user_agent NOT LIKE '%curl%' AND
        user_agent NOT LIKE '%wget%' AND
        user_agent NOT LIKE '%python%' AND
        user_agent NOT LIKE '%scrapy%' AND
        user_agent NOT LIKE '%headless%' AND
        user_agent NOT LIKE '%phantomjs%' AND
        user_agent NOT LIKE '%facebookexternalhit%' AND
        user_agent NOT LIKE '%Twitterbot%' AND
        user_agent NOT LIKE '%LinkedInBot%' AND
        user_agent NOT LIKE '%Bytespider%' AND
        user_agent NOT LIKE '%Applebot%' AND
        user_agent NOT LIKE '%HeadlessChrome%' AND
        user_agent NOT LIKE '%Android 10; K%' AND
        user_agent NOT LIKE '%PTST/%' AND
        ip_address NOT LIKE '66.249.%' AND
        ip_address NOT LIKE '192.178.%' AND
        -- Tencent Cloud
        ip_address NOT GLOB '1.12.*' AND ip_address NOT GLOB '1.13.*' AND
        ip_address NOT GLOB '1.14.*' AND ip_address NOT GLOB '1.15.*' AND
        ip_address NOT GLOB '1.92.*' AND
        ip_address NOT GLOB '43.12[89].*' AND ip_address NOT GLOB '43.13[0-9].*' AND
        ip_address NOT GLOB '43.14[0-9].*' AND ip_address NOT GLOB '43.15[0-9].*' AND
        ip_address NOT GLOB '43.16[0-3].*' AND
        ip_address NOT GLOB '49.51.*' AND
        ip_address NOT GLOB '101.32.*' AND ip_address NOT GLOB '101.33.*' AND
        ip_address NOT GLOB '101.34.*' AND ip_address NOT GLOB '101.35.*' AND
        ip_address NOT GLOB '101.42.*' AND ip_address NOT GLOB '101.43.*' AND
        ip_address NOT GLOB '119.28.*' AND ip_address NOT GLOB '119.29.*' AND
        ip_address NOT GLOB '124.156.*' AND ip_address NOT GLOB '124.157.*' AND
        ip_address NOT GLOB '129.226.*' AND
        ip_address NOT GLOB '170.106.*' AND
        -- Alibaba Cloud
        ip_address NOT GLOB '8.21[0-9].*' AND ip_address NOT GLOB '8.22[0-3].*' AND
        ip_address NOT GLOB '47.52.*' AND ip_address NOT GLOB '47.74.*' AND
        ip_address NOT GLOB '47.75.*' AND ip_address NOT GLOB '47.76.*' AND
        ip_address NOT GLOB '47.88.*' AND ip_address NOT GLOB '47.89.*' AND
        ip_address NOT GLOB '47.24[0-1].*' AND
        ip_address NOT GLOB '120.53.*' AND
        ip_address NOT GLOB '161.117.*' AND
        ip_address NOT GLOB '147.139.*' AND
        -- Huawei Cloud
        ip_address NOT GLOB '110.239.*' AND
        ip_address NOT GLOB '116.204.*' AND ip_address NOT GLOB '116.205.*' AND
        ip_address NOT GLOB '119.8.*' AND
        ip_address NOT GLOB '121.36.*' AND ip_address NOT GLOB '121.37.*' AND
        ip_address NOT GLOB '124.70.*' AND ip_address NOT GLOB '124.71.*' AND
        ip_address NOT GLOB '139.9.*' AND
        ip_address NOT GLOB '49.4.*' AND
        -- Other observed bot IPs
        ip_address NOT GLOB '82.157.*' AND
        ip_address NOT GLOB '113.44.*'"

        # Add US cloud/VPS filtering if strict mode enabled
        if [[ "$STRICT_BOTS" == "true" ]]; then
            filter="$filter AND
        -- DigitalOcean
        ip_address NOT GLOB '104.131.*' AND ip_address NOT GLOB '104.236.*' AND
        ip_address NOT GLOB '138.68.*' AND ip_address NOT GLOB '138.197.*' AND
        ip_address NOT GLOB '159.65.*' AND ip_address NOT GLOB '159.89.*' AND
        ip_address NOT GLOB '167.99.*' AND ip_address NOT GLOB '167.172.*' AND
        ip_address NOT GLOB '178.62.*' AND ip_address NOT GLOB '178.128.*' AND
        ip_address NOT GLOB '188.166.*' AND
        ip_address NOT GLOB '206.189.*' AND
        -- Linode
        ip_address NOT GLOB '45.33.*' AND ip_address NOT GLOB '45.56.*' AND
        ip_address NOT GLOB '45.79.*' AND
        ip_address NOT GLOB '50.116.*' AND
        ip_address NOT GLOB '69.164.*' AND
        ip_address NOT GLOB '72.14.*' AND
        ip_address NOT GLOB '139.162.*' AND
        ip_address NOT GLOB '172.104.*' AND
        ip_address NOT GLOB '173.255.*' AND
        ip_address NOT GLOB '192.155.*' AND
        ip_address NOT GLOB '198.58.*' AND
        -- Vultr
        ip_address NOT GLOB '45.32.*' AND ip_address NOT GLOB '45.63.*' AND
        ip_address NOT GLOB '45.76.*' AND ip_address NOT GLOB '45.77.*' AND
        ip_address NOT GLOB '66.42.*' AND
        ip_address NOT GLOB '104.156.*' AND ip_address NOT GLOB '104.238.*' AND
        ip_address NOT GLOB '108.61.*' AND
        ip_address NOT GLOB '140.82.*' AND
        ip_address NOT GLOB '149.28.*' AND
        ip_address NOT GLOB '207.148.*' AND
        ip_address NOT GLOB '209.250.*'"
        fi

        echo "$filter
        )"
    else
        echo ""
    fi
}

# Build URL filter (matches against normalized URL without fragments)
get_url_filter() {
    if [[ -n "$URL_FILTER" ]]; then
        echo "AND $URL_EXPR LIKE '%${URL_FILTER}%'"
    else
        echo ""
    fi
}

# Build referrer filter
get_referrer_filter() {
    if [[ -n "$REFERRER_FILTER" ]]; then
        echo "AND referrer LIKE '%${REFERRER_FILTER}%'"
    else
        echo ""
    fi
}

# Build secondary dimension select
get_by_select() {
    case $BY in
        referrer)
            echo ", CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END as by_dimension"
            ;;
        page)
            echo ", $URL_EXPR as by_dimension"
            ;;
        day)
            echo ", date(timestamp) as by_dimension"
            ;;
        *)
            echo ""
            ;;
    esac
}

get_by_group() {
    case $BY in
        referrer)
            echo ", CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END"
            ;;
        page)
            echo ", $URL_EXPR"
            ;;
        day)
            echo ", date(timestamp)"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Execute query
run_query() {
    sqlite3 -header -column "$DB_PATH" "$1"
}

# Execute query and render with chart
run_query_with_chart() {
    local query="$1"
    local output
    local header
    local separator
    local -a lines
    local -a values
    local max_val=0
    local metric_col=-1

    # Get tab-separated output for easier parsing
    output=$(sqlite3 -header -separator $'\t' "$DB_PATH" "$query")

    [[ -z "$output" ]] && return

    # Read into array
    IFS=$'\n' read -r -d '' -a lines <<< "$output" || true

    [[ ${#lines[@]} -lt 1 ]] && return

    header="${lines[0]}"
    IFS=$'\t' read -r -a cols <<< "$header"

    # Find the metric column (visitors, pageviews, recent_2d)
    for i in "${!cols[@]}"; do
        case "${cols[$i]}" in
            visitors|pageviews|recent_2d)
                metric_col=$i
                break
                ;;
        esac
    done

    # If no known metric column, just output normally
    if [[ $metric_col -lt 0 ]]; then
        run_query "$query"
        return
    fi

    # Find max value for scaling
    for ((i=1; i<${#lines[@]}; i++)); do
        IFS=$'\t' read -r -a row <<< "${lines[$i]}"
        val="${row[$metric_col]}"
        # Handle decimals by truncating
        val="${val%%.*}"
        [[ "$val" =~ ^[0-9]+$ ]] && (( val > max_val )) && max_val=$val
    done

    [[ $max_val -eq 0 ]] && max_val=1

    # Calculate column widths from data
    local -a col_widths
    for i in "${!cols[@]}"; do
        col_widths[$i]=${#cols[$i]}
    done

    for ((i=1; i<${#lines[@]}; i++)); do
        IFS=$'\t' read -r -a row <<< "${lines[$i]}"
        for j in "${!row[@]}"; do
            (( ${#row[$j]} > ${col_widths[$j]:-0} )) && col_widths[$j]=${#row[$j]}
        done
    done

    # Print header
    local header_line=""
    local sep_line=""
    for i in "${!cols[@]}"; do
        printf -v padded "%-${col_widths[$i]}s" "${cols[$i]}"
        header_line+="$padded  "
        printf -v dashes "%${col_widths[$i]}s" ""
        sep_line+="${dashes// /-}  "
    done
    echo "${header_line}chart"
    echo "${sep_line}$(printf '%*s' $BAR_WIDTH '' | tr ' ' '-')"

    # Print data rows with bars
    for ((i=1; i<${#lines[@]}; i++)); do
        IFS=$'\t' read -r -a row <<< "${lines[$i]}"
        local row_line=""
        for j in "${!row[@]}"; do
            printf -v padded "%-${col_widths[$j]}s" "${row[$j]}"
            row_line+="$padded  "
        done

        # Calculate bar length
        val="${row[$metric_col]}"
        val="${val%%.*}"
        [[ ! "$val" =~ ^[0-9]+$ ]] && val=0
        local bar_len=$(( (val * BAR_WIDTH) / max_val ))
        [[ $bar_len -eq 0 && $val -gt 0 ]] && bar_len=1

        # Draw bar
        local bar=""
        for ((b=0; b<bar_len; b++)); do
            bar+="█"
        done

        echo "${row_line}${bar}"
    done
}

# Build and run query based on metric
PERIOD_FILTER=$(get_period_filter)
BOT_FILTER=$(get_bot_filter)
URL_FILTER_SQL=$(get_url_filter)
REFERRER_FILTER_SQL=$(get_referrer_filter)
GROUP_SELECT=$(get_group_select)
GROUP_BY=$(get_group_by)
BY_SELECT=$(get_by_select)
BY_GROUP=$(get_by_group)

case $METRIC in
    visitors)
        if [[ -n "$GROUP_BY" ]]; then
            if [[ -n "$BY_SELECT" ]]; then
                if [[ -n "$PER_LIMIT" ]]; then
                    TOTAL_LIMIT=$((LIMIT * PER_LIMIT))
                    QUERY="WITH ranked AS (
                               SELECT $GROUP_SELECT $BY_SELECT, COUNT(DISTINCT ip_address) as visitors,
                                      ROW_NUMBER() OVER (PARTITION BY $GROUP_BY ORDER BY COUNT(DISTINCT ip_address) DESC) as rn
                               FROM understanding_data
                               WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                               GROUP BY $GROUP_BY $BY_GROUP
                           )
                           SELECT period, by_dimension, visitors
                           FROM ranked
                           WHERE rn <= $PER_LIMIT
                           ORDER BY period DESC, visitors DESC
                           LIMIT $TOTAL_LIMIT;"
                else
                    QUERY="SELECT $GROUP_SELECT $BY_SELECT, COUNT(DISTINCT ip_address) as visitors
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY $GROUP_BY $BY_GROUP
                           ORDER BY period DESC, visitors DESC
                           LIMIT $LIMIT;"
                fi
            else
                if needs_daily_avg; then
                    # Use CTEs to:
                    # 1. Get daily data
                    # 2. Find gaps using LAG/LEAD
                    # 3. Exclude days adjacent to gaps (partial data from outages)
                    QUERY="WITH daily_data AS (
                               SELECT $GROUP_BY as period,
                                      date(timestamp) as day,
                                      COUNT(DISTINCT ip_address) as daily_visitors
                               FROM understanding_data
                               WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                               GROUP BY $GROUP_BY, date(timestamp)
                           ),
                           gap_analysis AS (
                               SELECT period, day, daily_visitors,
                                      julianday(day) - julianday(LAG(day) OVER (ORDER BY day)) as gap_before,
                                      julianday(LEAD(day) OVER (ORDER BY day)) - julianday(day) as gap_after
                               FROM daily_data
                           ),
                           filtered AS (
                               SELECT period, day, daily_visitors
                               FROM gap_analysis
                               WHERE gap_before = 1 AND gap_after = 1
                           )
                           SELECT period, SUM(daily_visitors) as visitors, COUNT(*) as days, ROUND(AVG(daily_visitors), 1) as daily_avg
                           FROM filtered
                           GROUP BY period
                           ORDER BY period DESC
                           LIMIT $LIMIT;"
                else
                    QUERY="SELECT $GROUP_SELECT, COUNT(DISTINCT ip_address) as visitors
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY $GROUP_BY
                           ORDER BY period DESC
                           LIMIT $LIMIT;"
                fi
            fi
        else
            if [[ -n "$BY_SELECT" ]]; then
                # Strip leading comma from BY_GROUP for standalone GROUP BY
                BY_GROUP_CLEAN="${BY_GROUP#, }"
                QUERY="SELECT ${BY_SELECT#, }, COUNT(DISTINCT ip_address) as visitors
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $BY_GROUP_CLEAN
                       ORDER BY visitors DESC
                       LIMIT $LIMIT;"
            else
                QUERY="SELECT COUNT(DISTINCT ip_address) as visitors
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL;"
            fi
        fi
        ;;
    pageviews)
        if [[ -n "$GROUP_BY" ]]; then
            if [[ -n "$BY_SELECT" ]]; then
                if [[ -n "$PER_LIMIT" ]]; then
                    TOTAL_LIMIT=$((LIMIT * PER_LIMIT))
                    QUERY="WITH ranked AS (
                               SELECT $GROUP_SELECT $BY_SELECT, COUNT(*) as pageviews,
                                      ROW_NUMBER() OVER (PARTITION BY $GROUP_BY ORDER BY COUNT(*) DESC) as rn
                               FROM understanding_data
                               WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                               GROUP BY $GROUP_BY $BY_GROUP
                           )
                           SELECT period, by_dimension, pageviews
                           FROM ranked
                           WHERE rn <= $PER_LIMIT
                           ORDER BY period DESC, pageviews DESC
                           LIMIT $TOTAL_LIMIT;"
                else
                    QUERY="SELECT $GROUP_SELECT $BY_SELECT, COUNT(*) as pageviews
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY $GROUP_BY $BY_GROUP
                           ORDER BY period DESC, pageviews DESC
                           LIMIT $LIMIT;"
                fi
            else
                if needs_daily_avg; then
                    QUERY="WITH daily_data AS (
                               SELECT $GROUP_BY as period,
                                      date(timestamp) as day,
                                      COUNT(*) as daily_pageviews
                               FROM understanding_data
                               WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                               GROUP BY $GROUP_BY, date(timestamp)
                           ),
                           gap_analysis AS (
                               SELECT period, day, daily_pageviews,
                                      julianday(day) - julianday(LAG(day) OVER (ORDER BY day)) as gap_before,
                                      julianday(LEAD(day) OVER (ORDER BY day)) - julianday(day) as gap_after
                               FROM daily_data
                           ),
                           filtered AS (
                               SELECT period, day, daily_pageviews
                               FROM gap_analysis
                               WHERE gap_before = 1 AND gap_after = 1
                           )
                           SELECT period, SUM(daily_pageviews) as pageviews, COUNT(*) as days, ROUND(AVG(daily_pageviews), 1) as daily_avg
                           FROM filtered
                           GROUP BY period
                           ORDER BY period DESC
                           LIMIT $LIMIT;"
                else
                    QUERY="SELECT $GROUP_SELECT, COUNT(*) as pageviews
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY $GROUP_BY
                           ORDER BY period DESC
                           LIMIT $LIMIT;"
                fi
            fi
        else
            if [[ -n "$BY_SELECT" ]]; then
                # Strip leading comma from BY_GROUP for standalone GROUP BY
                BY_GROUP_CLEAN="${BY_GROUP#, }"
                QUERY="SELECT ${BY_SELECT#, }, COUNT(*) as pageviews
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $BY_GROUP_CLEAN
                       ORDER BY pageviews DESC
                       LIMIT $LIMIT;"
            else
                QUERY="SELECT COUNT(*) as pageviews
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL;"
            fi
        fi
        ;;
    pages)
        if [[ -n "$BY_SELECT" ]]; then
            if [[ -n "$PER_LIMIT" ]]; then
                TOTAL_LIMIT=$((LIMIT * PER_LIMIT))
                QUERY="WITH ranked AS (
                           SELECT $URL_EXPR as url, COUNT(DISTINCT ip_address) as visitors $BY_SELECT,
                                  ROW_NUMBER() OVER (PARTITION BY $URL_EXPR ORDER BY COUNT(DISTINCT ip_address) DESC) as rn
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY $URL_EXPR $BY_GROUP
                       )
                       SELECT url, visitors, by_dimension
                       FROM ranked
                       WHERE rn <= $PER_LIMIT
                       ORDER BY visitors DESC
                       LIMIT $TOTAL_LIMIT;"
            else
                QUERY="SELECT $URL_EXPR as url, COUNT(DISTINCT ip_address) as visitors $BY_SELECT
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $URL_EXPR $BY_GROUP
                       ORDER BY visitors DESC
                       LIMIT $LIMIT;"
            fi
        else
            QUERY="SELECT $URL_EXPR as url, COUNT(DISTINCT ip_address) as visitors, COUNT(*) as pageviews
                   FROM understanding_data
                   WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY $URL_EXPR
                   ORDER BY visitors DESC
                   LIMIT $LIMIT;"
        fi
        ;;
    referrers)
        if [[ -n "$BY_SELECT" ]]; then
            if [[ -n "$PER_LIMIT" ]]; then
                TOTAL_LIMIT=$((LIMIT * PER_LIMIT))
                QUERY="WITH ranked AS (
                           SELECT CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END as referrer,
                                  COUNT(DISTINCT ip_address) as visitors $BY_SELECT,
                                  ROW_NUMBER() OVER (PARTITION BY CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END ORDER BY COUNT(DISTINCT ip_address) DESC) as rn
                           FROM understanding_data
                           WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                           GROUP BY 1 $BY_GROUP
                       )
                       SELECT referrer, visitors, by_dimension
                       FROM ranked
                       WHERE rn <= $PER_LIMIT
                       ORDER BY visitors DESC
                       LIMIT $TOTAL_LIMIT;"
            else
                QUERY="SELECT CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END as referrer,
                              COUNT(DISTINCT ip_address) as visitors $BY_SELECT
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY 1 $BY_GROUP
                       ORDER BY visitors DESC
                       LIMIT $LIMIT;"
            fi
        else
            QUERY="SELECT CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END as referrer,
                          COUNT(DISTINCT ip_address) as visitors,
                          COUNT(*) as pageviews
                   FROM understanding_data
                   WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY 1
                   ORDER BY visitors DESC
                   LIMIT $LIMIT;"
        fi
        ;;
    trending)
        # Compare recent period (last 2 days) vs baseline (previous 14 days avg)
        QUERY="WITH recent AS (
                   SELECT $URL_EXPR as url, COUNT(DISTINCT ip_address) as recent_visitors
                   FROM understanding_data
                   WHERE timestamp >= datetime('now', '-2 days')
                   $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY $URL_EXPR
               ),
               baseline AS (
                   SELECT $URL_EXPR as url, COUNT(DISTINCT ip_address) / 14.0 as daily_avg_visitors
                   FROM understanding_data
                   WHERE timestamp >= datetime('now', '-16 days')
                     AND timestamp < datetime('now', '-2 days')
                   $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY $URL_EXPR
               )
               SELECT r.url,
                      r.recent_visitors as recent_2d,
                      ROUND(COALESCE(b.daily_avg_visitors, 0), 1) as baseline_daily_avg,
                      ROUND(r.recent_visitors / 2.0, 1) as recent_daily_avg,
                      CASE
                          WHEN COALESCE(b.daily_avg_visitors, 0) = 0 THEN 'new'
                          ELSE ROUND((r.recent_visitors / 2.0) / b.daily_avg_visitors, 1) || 'x'
                      END as spike
               FROM recent r
               LEFT JOIN baseline b ON r.url = b.url
               WHERE r.recent_visitors >= 2
                 AND (COALESCE(b.daily_avg_visitors, 0) = 0
                      OR (r.recent_visitors / 2.0) > (b.daily_avg_visitors * 2))
               ORDER BY r.recent_visitors DESC
               LIMIT $LIMIT;"
        ;;
    *)
        echo "Error: Unknown metric '$METRIC'"
        echo "Valid metrics: visitors, pageviews, pages, referrers, trending"
        exit 1
        ;;
esac

if [[ "$CHART" == "true" ]]; then
    run_query_with_chart "$QUERY"
else
    run_query "$QUERY"
fi
