"""No network: validate recovery TLS policy before any subprocess is started."""
import sys
import unittest
import os
import runpy
from unittest.mock import patch

sys.path.insert(0, "/recovery")
from connect import connection


class ConnectionTests(unittest.TestCase):
    def test_remote_requires_verify_full(self):
        for mode in (None, "", "disable", "allow", "prefer", "require", "verify-ca"):
            for optout in (False, True):
                with self.subTest(mode=mode, optout=optout), self.assertRaises(ValueError):
                    suffix = "" if mode is None else "?sslmode=" + mode
                    connection("postgresql://user:synthetic@db.example/test" + suffix, optout)

    def test_remote_verified_system_and_custom_roots(self):
        for suffix, root in (("", "/etc/ssl/certs/ca-certificates.crt"),
                             ("&sslrootcert=system", "/etc/ssl/certs/ca-certificates.crt"),
                             ("&sslrootcert=/run/database-ca.crt", "/run/database-ca.crt")):
            values = connection("postgresql://user:synthetic@db.example/test?sslmode=verify-full" + suffix)
            self.assertEqual(values["PGSSLMODE"], "verify-full")
            self.assertEqual(values["PGSSLROOTCERT"], root)
            self.assertEqual(values["PGHOST"], "db.example")

    def test_local_requires_explicit_optout(self):
        for host in ("localhost", "127.0.0.1", "[::1]"):
            url = "postgresql://postgres@" + host + "/test?sslmode=disable"
            with self.assertRaises(ValueError):
                connection(url)
            self.assertEqual(connection(url, True)["PGSSLMODE"], "disable")
        self.assertEqual(connection("postgresql:///test?host=/tmp&sslmode=disable", True)["PGHOST"], "/tmp")

    def test_ambiguous_routes_and_roots_rejected(self):
        for query in ("host=localhost.evil&sslmode=disable", "host=localhost,db.example&sslmode=disable",
                      "host=/tmp/../tmp&sslmode=disable", "sslmode=disable",
                      "host=db.example&sslmode=verify-full&sslmode=disable",
                      "host=db.example&sslmode=verify-full&sslrootcert=/tmp/untrusted",
                      "host=localhost&hostaddr=203.0.113.1&sslmode=disable"):
            with self.subTest(query=query), self.assertRaises((ValueError, KeyError)):
                connection("postgresql:///test?" + query, True)

    def test_inherited_libpq_overrides_cleared_before_exec(self):
        env = {"DATABASE_URL": "postgresql://user:synthetic@db.example/test?sslmode=verify-full",
               "PGHOSTADDR": "203.0.113.1", "PGSERVICE": "insecure",
               "PGSSLMODE": "disable", "PGSSLROOTCERT": "/tmp/untrusted"}
        with patch.dict(os.environ, env, clear=True), patch("os.execvpe") as execute:
            runpy.run_path("/recovery/connect.py", run_name="__main__")
            self.assertNotIn("PGHOSTADDR", os.environ)
            self.assertNotIn("PGSERVICE", os.environ)
            self.assertNotIn("DATABASE_URL", os.environ)
            self.assertEqual(os.environ["PGSSLMODE"], "verify-full")
            self.assertEqual(os.environ["PGGSSENCMODE"], "disable")
            execute.assert_called_once()


if __name__ == "__main__":
    unittest.main()
