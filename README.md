Uses `goaccess` to generate pretty, **monthly** and **yearly** access logs for a few sites I have deployed in S3/CloudFront. You can see [some reports here](https://reports.nikhil.io/).

Involves two separate buckets:

1. One that collects all the logs across all sites and has some expiration policy on its objects.
2. Another that [simply hosts the reports](https://reports.nikhil.io/).

Requires `bash`, `goaccess` v1.5+, `geoipupdate`, and `awscli` to be installed. As of now, will only work with CloudFront logs since that's all I deal with. Super-easy to adapt to other kinds of logs.

## Setup

### Ubuntu

```bash
sudo apt install geoipupdate goaccess
```

### FreeBSD

On FreeBSD 11.2. FreshPorts' package is not compiled with support for Tokyo Cabinet. A bit more [involved](https://github.com/allinurl/goaccess/issues/1467) than that I thought it would be.

```bash
# Install deps
pkg install \
    tcb \
    gettext \
    libmaxminddb \
    automake \
    python3.7 \
    geoipupdate \
    awscli

# Compile goaccess
git clone https://github.com/allinurl/goaccess.git
cd goaccess
autoreconf -fiv
./configure \
    --enable-utf8 \
    --enable-geoip=mmdb \
    --enable-tcb=btree \
    CFLAGS="-I/usr/local/include" \
    LDFLAGS="-L/usr/local/lib"

make
make install
```

### GeoIP Information

You will need [the GeoIP configuration information](https://dev.maxmind.com/geoip/updating-databases?lang=en#2-obtain-geoipconf-with-account-information) from MaxMind. Get a MaxMind account and API key and, in this folder,

```bash
mkdir ./geoip
geoipupdate -d ./geoip
```

The script will fail if you don't do this.

### Running the Script

With `aws` and `goaccess` in your `$PATH` (and the GeoIP data in `./geoip`), you need to specify (a) the bucket to pull logs from and (b) the bucket to push generated reports to. Here's a sample invocation:

```shell
./generate.sh \
    --reports-bucket reports.example.com \
    --logs-bucket logs.example.com \
    --website foo.example.com
```

Add `--no-fetch-logs` or `--no-sync-logs` to disable automatic fetching and syncing.

You will need the AWS CLI configured to pull and push to your buckets. Assumed that this is the `default` profile; customize as you see fit.

The logs will be downloaded to (or must exist in) `./websites/foo.example.com/logs` (will be created if it doesn't exist). Many `goaccess` databases will be created at `./websites/foo.example.com/db` for incremental reporting.

👉 Back up the generated reports in `./reports/foo.example.com` !

## License

[WTFPL](https://www.wtfpl.net/)
