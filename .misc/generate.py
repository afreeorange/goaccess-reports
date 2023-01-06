"""
THIS IS DEPRECATED.

I replaced this with a simple bash script.
"""

import logging
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from distutils.spawn import find_executable
from glob import glob

LOGS_BUCKET = "logs.example.com"
REPORTS_BUCKET = "reports.example.com"
SITES = {
    "example.com": {"type": "CLOUDFRONT"},
    "public.example.com": {"type": "CLOUDFRONT"},
}
REQUIRED_COMMANDS = ["find", "goaccess", "zcat", "aws"]


logging.basicConfig(
    level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s"
)
log = logging.getLogger("Generator")


def clean_logs(site_name):
    """
    Removes the local logs copy
    """
    try:
        shutil.rmtree(f"{site_name}/logs")
    except FileNotFoundError:
        pass


def prepare_site_folder(site_name):
    """
    Creates a site folder containing a GoAccess database (for faster report
    generation) and a copy of logs in the logs bucket.
    """
    try:
        os.makedirs(f"{site_name}/logs", exist_ok=True)
        os.makedirs(f"{site_name}/db", exist_ok=True)
    except FileExistsError:
        pass


def prepare_report_folder(site_name, year, month):
    """
    Creates a report structure locally (year/month) if it doesn't exist
    """
    try:
        os.makedirs(f"./reports/{site_name}/{year}/{month}")
        shutil.copyfile("./custom.css", f"./reports/{site_name}/custom.css")
    except FileExistsError:
        pass


def sync_logs(site_name, bucket=LOGS_BUCKET):
    """
    Syncs S3 or CloudFront logs from the logs bucket locally **with deletion**
    """
    p = subprocess.Popen(
        f'aws s3 sync "s3://{bucket}/{site_name}/" "./{site_name}/logs/"',
        shell=True,
    )
    p.communicate()

    # (out, err) = p.communicate()
    # log.info(f"Finished syncing. Output: {out}")
    # log.info(f"Finished syncing. Errors: {err}")


def sync_reports(bucket=LOGS_BUCKET):
    """
    Syncs generated HTML reports to the reports bucket **with deletion**
    """
    p = subprocess.Popen(
        f"aws s3 sync reports/ s3://{REPORTS_BUCKET}/",
        shell=True,
    )
    p.communicate()


def generate_report(site_name, log_type, year, month=None):
    """
    Generates a yearly or monthly report based on the supplied arguments.
    """
    the_glob = f"*{year}-{month}*"
    report_path = f"./reports/{site_name}/{year}/{month}/index.html"
    report_title = f"{site_name} - {year} - {month}"

    if month is None:
        the_glob = f"*{year}*"
        report_path = f"./reports/{site_name}/{year}/index.html"
        report_title = f"{site_name} - {year}"

    # Handle S3 or CloudFront logs. Use find to prevent errors like these:
    #
    #   The total size of the argument and environment lists 248kB exceeds the
    #   operating system limit of 256kB.
    #
    # Note that we're not using zcat since macOS is very silly about it.
    #
    stream_command = (
        f"find ./{site_name}/logs/ -type f -name '{the_glob}' -exec gunzip -c {{}} \\;"
    )
    if log_type == "CLOUDFRONT":
        stream_command = f"find ./{site_name}/logs/ -type f -name '{the_glob}.gz' -exec gunzip -c {{}} \\;"

    # Create DB if first time setup. Load from DB otherwise.
    # db_load_flags = "--keep-db-files"
    # if len(os.listdir(f"./{site_name}/db")) != 0:
    #     log.debug(f"Using local database ./{site_name}/db")
    #     db_load_flags = "--load-from-disk"

    report_command = f"""
        goaccess \
            --log-format {log_type} - \
            --geoip-database=./geoip/GeoLite2-City.mmdb \
            --with-output-resolver \
            --agent-list \
            --ignore-crawlers \
            --real-os \
            --json-pretty-print \
            --db-path=./{site_name}/db/ \
            --persist \
            --output={report_path} \
            --html-prefs='{{"theme":"bright"}}'\
            --html-custom-css=/custom.css \
            --html-report-title='{report_title}'
        """

    process_stream = subprocess.Popen(
        stream_command, shell=True, stdout=subprocess.PIPE
    )

    process_logs = subprocess.Popen(
        report_command, shell=True, stdin=process_stream.stdout
    )

    process_logs.communicate()[0]


def unique_years_and_months(site_name):
    d = defaultdict(list)
    ret = {}

    for path in glob(f"./{site_name}/logs/*"):
        s = re.search(r".*(\d{4})-(\d{2}).*", path)
        d[s.group(1)].append(s.group(2))

    for year, months in d.items():
        ret[year] = set(months)

    return ret


if __name__ == "__main__":

    for command in REQUIRED_COMMANDS:
        if find_executable(command) is None:
            log.error(f"! Could not find the command '{command}' in PATH. Quitting.")
            sys.exit(1)

    for site_name in SITES.keys():
        log.info(f"Starting {site_name}")
        log.info("-" * (8 + len(site_name)))

        log.info("Preparing data folders")
        prepare_site_folder(site_name)

        log.info("Syncing logs")
        sync_logs(site_name)

        for year, months in unique_years_and_months(site_name).items():
            log.info(f"Generating report for {site_name} for {year}")
            generate_report(site_name, SITES[site_name]["type"], year)

            for month in months:
                prepare_report_folder(site_name, year, month)

                log.info(f"Generating report for {site_name} for {year}/{month}")
                generate_report(site_name, SITES[site_name]["type"], year, month)

        log.info("-" * (8 + len(site_name)))

    log.info("Syncing all reports")
    sync_reports()
