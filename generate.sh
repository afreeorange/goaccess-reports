#!/usr/bin/env bash

set -euo pipefail

# TODO: Sliding window problem (in relation to retention policies)? This is
#       pretty severe... does the presistence of the goaccess database solve
#       this problem?
#
#       MAYBE: If the current year is not the year, skip it. Reports
#       have already been generated.
#
# TODO: Check the current month and assume that all prior months have been
#       generated?

REPORTS_BUCKET=""
LOGS_BUCKET=""
WEBSITE=""
FETCH_LOGS=1
SYNC_LOGS=1
LOGFILE_TYPE="CLOUDFRONT"
GEO_IP_DB_LOCATION="./geoip/GeoLite2-Country.mmdb"
REPORTS_LOCATION="./reports"
WEBSITES_LOCATION="./websites"
MONTHS=(
    "01"
    "02"
    "03"
    "04"
    "05"
    "06"
    "07"
    "08"
    "09"
    "10"
    "11"
    "12"
)

# --- Parse CLI Args ---

usage() {
    echo "USAGE:"
    echo "$0 --reports-bucket <bucket> --logs-bucket <bucket> --website <name>"
    echo ""
    echo "Bucket names should not be prefixed with s3:// and should not end in /"
    echo "Just the domain and TLD for the website name (e.g. example.com)"
    echo ""
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --reports-bucket)
            REPORTS_BUCKET="${2#*://}"  # strip protocol
            REPORTS_BUCKET="${REPORTS_BUCKET%/}"  # strip trailing slash
            shift 2
        ;;
        --logs-bucket)
            LOGS_BUCKET="${2#*://}"
            LOGS_BUCKET="${LOGS_BUCKET%/}"
            shift 2
        ;;
        --website)
            WEBSITE="${2#*://}"
            WEBSITE="${WEBSITE%/}"
            shift 2
        ;;
        --no-fetch-logs)
            FETCH_LOGS=0
            shift
        ;;
        --no-sync-logs)
            SYNC_LOGS=0
            shift
        ;;
        *)
            echo "Unknown option: $1"
            usage
        ;;
    esac
done

if [[ -z $REPORTS_BUCKET || -z $LOGS_BUCKET || -z $WEBSITE ]]; then
    usage
fi

# --- Sanity Checks ---

if ! command -v aws >>/dev/null 2>&1; then
    echo "You need the AWS CLI installed and in PATH"
    exit 10
fi

# Requires goaccess 1.5+ but I'm too lazy to write a check for this...
if ! command -v goaccess >>/dev/null 2>&1; then
    echo "You will need goaccess installed and in PATH"
    exit 20
fi

if [[ ! -f "./geoip/GeoLite2-Country.mmdb" ]]; then
    echo "I use the MaxMind GeoIP Database (the free stuff)"
    echo "Please install it and make sure the databases are in ./geoip"
    echo "Then just run"
    echo ""
    echo "      mkdir ./geoip"
    echo "      geoipupdate -d ./geoip"
    echo ""
    exit 30
fi

# --- Some basic prep ---

mkdir -p "$WEBSITES_LOCATION/$WEBSITE"/{db,logs}
mkdir -p "$REPORTS_LOCATION/$WEBSITE"

# --- GoAccess function ---

run_goaccess() {
    local output_location="$1"
    local title="$2"
    local db_location="$3"

    goaccess - \
    --log-format="$LOGFILE_TYPE" \
    --date-format="$LOGFILE_TYPE" \
    --time-format="$LOGFILE_TYPE" \
    --ignore-crawlers \
    --ignore-status=301 \
    --ignore-status=302 \
    --geoip-database="$GEO_IP_DB_LOCATION" \
    --with-output-resolver \
    --agent-list \
    --real-os \
    --json-pretty-print \
    --db-path="$db_location" \
    --persist \
    --restore \
    --output="$output_location" \
    --html-report-title="$title" \
    --html-custom-css="custom.css"
}

# --- Fetch Raw Logs ---

if [[ $FETCH_LOGS -eq 1 ]]; then
    echo "Fetching logs for $WEBSITE from $LOGS_BUCKET"
    aws s3 sync "s3://$LOGS_BUCKET/$WEBSITE/" "./$WEBSITES_LOCATION/$WEBSITE/logs/"
    echo "Done"
fi

# --- Generate Reports ---

mapfile -t YEARS < <(
    find "$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*.gz" -exec basename {} \; |
    cut -d"." -f2 |
    cut -d"-" -f1 |
    sort -u
)

echo "Found years:" "${YEARS[@]}"

#
# Main loop. Copypasta is OK. Breathe.
#
for YEAR in "${YEARS[@]}"; do
    echo "Generating logs for $YEAR"

    mkdir -p "$REPORTS_LOCATION/$WEBSITE/$YEAR"
    cp -v ./custom.css "$REPORTS_LOCATION/$WEBSITE/$YEAR/"
    mkdir -p "$WEBSITES_LOCATION/$WEBSITE/db/$YEAR"

    find "$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*.$YEAR-*.gz" -exec gunzip -c {} \; |
    run_goaccess \
    "$REPORTS_LOCATION/$WEBSITE/$YEAR/index.html" \
    "$WEBSITE - $YEAR" \
    "$WEBSITES_LOCATION/$WEBSITE/db/$YEAR"

    # Now do months. Whichever ones you find that is.
    for MONTH in "${MONTHS[@]}"; do
        mapfile -t LOGS < <(find "$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*.$YEAR-$MONTH*.gz")

        if [[ ${#LOGS[@]} -ne 0 ]]; then
            echo "Generating logs for $YEAR - $MONTH"

            mkdir -p "$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH"
            cp -v ./custom.css "$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH/"
            mkdir -p "$WEBSITES_LOCATION/$WEBSITE/db/$YEAR-$MONTH"

            find "$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*.$YEAR-$MONTH*.gz" -exec gunzip -c {} \; |
            run_goaccess \
            "$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH/index.html" \
            "$WEBSITE - $YEAR/$MONTH" \
            "$WEBSITES_LOCATION/$WEBSITE/db/$YEAR-$MONTH"
        fi
    done
done

# --- Sync Reports ---

# Note that we're not deleting anything here. That's for another process. Take
# backups of this reports bucket! What it contains is the 'precipitate' of all
# the raw logs.
if [[ $SYNC_LOGS -eq 1 ]]; then
    echo "Syncing logs to s3://$REPORTS_BUCKET/$WEBSITE/"
    aws s3 sync "$REPORTS_LOCATION/$WEBSITE/" "s3://$REPORTS_BUCKET/$WEBSITE/"
    echo "Done"
fi

