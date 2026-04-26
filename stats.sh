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
URL_FILTER=""
REFERRER_FILTER=""
INCLUDE_BOTS=false
CHART=false
BAR_WIDTH=30

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
  --url <pattern>         Filter by URL substring
  --referrer <pattern>    Filter by referrer substring
  --include-bots          Include bot traffic (excluded by default)
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
  week        Group by week
  month       Group by month
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

  # Daily visitors with bar chart
  ./stats.sh -m visitors -g day --chart
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

# Build period filter
get_period_filter() {
    case $PERIOD in
        today)
            echo "date(timestamp) = date('now')"
            ;;
        yesterday)
            echo "date(timestamp) = date('now', '-1 day')"
            ;;
        week)
            echo "timestamp >= datetime('now', '-7 days')"
            ;;
        month)
            echo "timestamp >= datetime('now', '-30 days')"
            ;;
        year)
            echo "timestamp >= datetime('now', '-365 days')"
            ;;
        all)
            echo "1=1"
            ;;
        *)
            echo "timestamp >= datetime('now', '-7 days')"
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
        echo "AND (user_agent NOT LIKE '%bot%' AND user_agent NOT LIKE '%Bot%' AND user_agent NOT LIKE '%crawler%' AND user_agent NOT LIKE '%spider%' AND user_agent NOT LIKE '%Googlebot%' AND user_agent NOT LIKE '%Bingbot%' AND user_agent NOT LIKE '%baiduspider%' AND user_agent NOT LIKE '%yandex%' AND user_agent NOT LIKE '%DuckDuckBot%' AND user_agent NOT LIKE '%curl%' AND user_agent NOT LIKE '%wget%' AND user_agent NOT LIKE '%python%' AND user_agent NOT LIKE '%scrapy%' AND user_agent NOT LIKE '%headless%' AND user_agent NOT LIKE '%phantomjs%' AND user_agent NOT LIKE '%facebookexternalhit%' AND user_agent NOT LIKE '%Twitterbot%' AND user_agent NOT LIKE '%LinkedInBot%')"
    else
        echo ""
    fi
}

# Build URL filter
get_url_filter() {
    if [[ -n "$URL_FILTER" ]]; then
        echo "AND url LIKE '%${URL_FILTER}%'"
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
            echo ", url as by_dimension"
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
            echo ", url"
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
                QUERY="SELECT $GROUP_SELECT $BY_SELECT, COUNT(DISTINCT ip_address) as visitors
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $GROUP_BY $BY_GROUP
                       ORDER BY period DESC, visitors DESC
                       LIMIT $LIMIT;"
            else
                QUERY="SELECT $GROUP_SELECT, COUNT(DISTINCT ip_address) as visitors
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $GROUP_BY
                       ORDER BY period DESC
                       LIMIT $LIMIT;"
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
                QUERY="SELECT $GROUP_SELECT $BY_SELECT, COUNT(*) as pageviews
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $GROUP_BY $BY_GROUP
                       ORDER BY period DESC, pageviews DESC
                       LIMIT $LIMIT;"
            else
                QUERY="SELECT $GROUP_SELECT, COUNT(*) as pageviews
                       FROM understanding_data
                       WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                       GROUP BY $GROUP_BY
                       ORDER BY period DESC
                       LIMIT $LIMIT;"
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
            QUERY="SELECT url, COUNT(DISTINCT ip_address) as visitors $BY_SELECT
                   FROM understanding_data
                   WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY url $BY_GROUP
                   ORDER BY visitors DESC
                   LIMIT $LIMIT;"
        else
            QUERY="SELECT url, COUNT(DISTINCT ip_address) as visitors, COUNT(*) as pageviews
                   FROM understanding_data
                   WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY url
                   ORDER BY visitors DESC
                   LIMIT $LIMIT;"
        fi
        ;;
    referrers)
        if [[ -n "$BY_SELECT" ]]; then
            QUERY="SELECT CASE WHEN referrer = '' OR referrer IS NULL THEN '(direct)' ELSE referrer END as referrer,
                          COUNT(DISTINCT ip_address) as visitors $BY_SELECT
                   FROM understanding_data
                   WHERE $PERIOD_FILTER $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY 1 $BY_GROUP
                   ORDER BY visitors DESC
                   LIMIT $LIMIT;"
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
                   SELECT url, COUNT(DISTINCT ip_address) as recent_visitors
                   FROM understanding_data
                   WHERE timestamp >= datetime('now', '-2 days')
                   $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY url
               ),
               baseline AS (
                   SELECT url, COUNT(DISTINCT ip_address) / 14.0 as daily_avg_visitors
                   FROM understanding_data
                   WHERE timestamp >= datetime('now', '-16 days')
                     AND timestamp < datetime('now', '-2 days')
                   $BOT_FILTER $URL_FILTER_SQL $REFERRER_FILTER_SQL
                   GROUP BY url
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
