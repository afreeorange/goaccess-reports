#!/bin/bash

# TODO: Sliding window problem (in relation to retention policies)? This is
#       pretty severe... does the presistence of the goaccess database solve
#       this problem?
#       MAYBE: If the current year is not the year, skip it. Reports
#       have already been generated.
#
# TODO: Check the current month and assume that all prior months have been
#       generated?

LOGFILE_TYPE="CLOUDFRONT"
GEO_IP_DB_LOCATION="./geoip/GeoLite2-Country.mmdb"
REPORTS_LOCATION="./reports"
WEBSITES_LOCATION="./websites"

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
    echo "  mkdir ./geoip"
    echo "  geoipupdate -d ./geoip"
    exit 30
fi

if [[ -z $BUCKET_FOR_LOGS ]]; then
    echo "You need to set an environment variable that tells me where to fetch the logs from."
    echo "It's called 'BUCKET_FOR_LOGS' and it's an S3 bucket (without the prefix!)."
    echo "Here's an example:"
    echo "  export BUCKET_FOR_LOGS=logs.example.com"
    exit 40
fi

if [[ -z $BUCKET_FOR_REPORTS ]]; then
    echo "You need to set an environment variable that tells me where to push the generated reports."
    echo "It's called 'BUCKET_FOR_REPORTS' and it's an S3 bucket (without the prefix!)."
    echo "Here's an example:"
    echo "  export BUCKET_FOR_REPORTS=reports.example.com"
    exit 50
fi

WEBSITE=""
if [[ -z $1 ]]; then
    echo "You need to give me a website that I should generate reports format."
    echo "This is the first argument you provide to this script."
    exit 60
fi
WEBSITE=$1

# Assumption here is that all logs for months, years past have already been
# generated.

CURRENT_YEAR=$(date "+%Y")
CURRENT_MONTH=$(date "+%m")
if [[ -n $2 ]]; then
    echo "Only generating reports for $CURRENT_YEAR - $CURRENT_MONTH"
    MONTHS=("$CURRENT_MONTH")
    YEARS=("$CURRENT_YEAR")
else
    # We just go through all months lazily. `find` is "fast enough". Chill.
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

    # Get the number of unique years we're dealing with. This will only work for
    # CloudFront logs and that's OK for now...
    YEARS=($(find ./$WEBSITES_LOCATION/$WEBSITE/logs -type f -iname "*.gz" | sort | xargs basename | cut -d"." -f2 | cut -d"-" -f1 | sort | uniq))
fi

# --- Fetch Raw Logs ---

echo "Fetching logs for $WEBSITE from $BUCKET_FOR_LOGS"
mkdir -p ./"$WEBSITES_LOCATION"/"$WEBSITE"/{db,logs}
aws s3 sync "s3://$BUCKET_FOR_LOGS/$WEBSITE/" "./websites/$WEBSITE/logs/"

# TODO: Check if there are any logs and exit with a nice message...

# --- Generate Reports ---

mkdir -p "$REPORTS_LOCATION/$WEBSITE"

for YEAR in "${YEARS[@]}"; do
    mkdir -p "$REPORTS_LOCATION/$WEBSITE/$YEAR"

    # Generate yearly logs
    echo "Generating logs for $YEAR"
    mkdir -p "$REPORTS_LOCATION/$WEBSITE/$YEAR"
    cp -v ./custom.css "$REPORTS_LOCATION/$WEBSITE/$YEAR/"

    find "./$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*$YEAR*.gz" -exec gunzip -c {} \; |
        goaccess \
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
            --db-path="./$WEBSITES_LOCATION/$WEBSITE/db" \
            --persist \
            --output="./$REPORTS_LOCATION/$WEBSITE/$YEAR/index.html" \
            --html-report-title="$WEBSITE - $YEAR" \
            --html-custom-css="custom.css"

    for MONTH in "${MONTHS[@]}"; do

        # Just be relatively 'clean' and only generate logs for the month you
        # find. This also SHOULD NOT TOUCH the reports that have been generated
        # before when you generate/sync!
        LOGS=($(find ./$WEBSITES_LOCATION/$WEBSITE/logs -type f -iname "*$YEAR-$MONTH*.gz"))
        if [[ ${#LOGS[@]} -ne 0 ]]; then
            echo "Generating logs for $YEAR - $MONTH"
            mkdir -p "$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH"
            cp -v ./custom.css "$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH/"

            # Copypasta is OK. Breathe.
            find "./$WEBSITES_LOCATION/$WEBSITE/logs" -type f -iname "*$YEAR-$MONTH*.gz" -exec gunzip -c {} \; |
                goaccess \
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
                    --db-path="./$WEBSITES_LOCATION/$WEBSITE/db" \
                    --persist \
                    --output="./$REPORTS_LOCATION/$WEBSITE/$YEAR/$MONTH/index.html" \
                    --html-report-title="$WEBSITE - $YEAR - $MONTH" \
                    --html-custom-css="custom.css"
        fi
    done
done

# --- Sync Reports ---

# Note that we're not deleting anything here! Keep the old stuff in place! AND
# TAKE BACKUPS OF THIS BUCKET! What it contains is the 'precipitate' of all the
# raw logs.
aws s3 sync "./$REPORTS_LOCATION/$WEBSITE/" "s3://$BUCKET_FOR_REPORTS/$WEBSITE/"

