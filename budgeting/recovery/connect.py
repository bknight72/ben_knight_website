"""Translate a private URL into libpq environment, never process arguments."""
import os
import sys
import ipaddress
from urllib.parse import parse_qsl, unquote, urlsplit


def connection(raw, local_synthetic=False):
    url = urlsplit(raw)
    if url.scheme not in ("postgresql", "postgres") or not url.path[1:]:
        raise ValueError()
    values = {"PGDATABASE": unquote(url.path[1:]), "PGGSSENCMODE": "disable"}
    for key, value in (("PGHOST", url.hostname), ("PGPORT", url.port),
                       ("PGUSER", url.username), ("PGPASSWORD", url.password)):
        if value is not None:
            values[key] = unquote(str(value))
    options = {"sslmode": "PGSSLMODE", "sslrootcert": "PGSSLROOTCERT",
               "sslcert": "PGSSLCERT", "sslkey": "PGSSLKEY", "host": "PGHOST"}
    seen = set()
    for key, value in parse_qsl(url.query, strict_parsing=True, keep_blank_values=True):
        if key in seen:
            raise ValueError()
        seen.add(key)
        values[options[key]] = value
    host = values.get("PGHOST", "")
    if not host or any(c.isspace() or c == "," or c == "\x00" for c in host):
        raise ValueError()
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host == "localhost"
    unix_socket = host.startswith("/") and os.path.normpath(host) == host and not host.startswith("//")
    mode = values.get("PGSSLMODE")
    if mode != "verify-full":
        if not (local_synthetic and (loopback or unix_socket) and mode == "disable"):
            raise ValueError()
    else:
        root = values.get("PGSSLROOTCERT", "system")
        if root not in ("system", "/run/database-ca.crt"):
            raise ValueError()
        values["PGSSLROOTCERT"] = "/etc/ssl/certs/ca-certificates.crt" if root == "system" else root
    return values


if __name__ == "__main__":
    try:
        values = connection(os.environ.pop("DATABASE_URL"),
                            os.environ.pop("RECOVERY_LOCAL_SYNTHETIC", "") == "true")
    except (KeyError, ValueError):
        sys.exit("Invalid database configuration: require explicit host and sslmode=verify-full with system/mounted CA roots; sslmode=disable requires RECOVERY_LOCAL_SYNTHETIC=true and loopback/Unix socket (values withheld).")
    # Reject inherited libpq routing/service/TLS overrides, including PGHOSTADDR.
    for key in list(os.environ):
        if key.startswith("PG"):
            del os.environ[key]
    os.environ.update(values)
    os.execvpe("bash", ["bash", "/recovery/run.sh", *sys.argv[1:]], os.environ)
