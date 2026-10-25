"""End-to-end tests for install.sh (macOS) and install.ps1 (Windows).

Each test runs the script the way users do (`curl -fsSL <url>/install.sh | bash`,
`irm <url>/install.ps1 | iex`) against a local fake of the Flexile release API and PostHog, with
HOME / APPDATA pointing at a temporary folder. Standard library only.

    python3 tests/test_install.py              # the shells this OS has
    FLEXILE_TEST_SHELLS=pwsh python3 tests/test_install.py
"""

import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import tempfile
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IS_WINDOWS = platform.system() == "Windows"
BUNDLE_ID = "com.flexile.bc.io"
# The shell that runs install.sh: macOS ships bash 3.2 as /bin/bash, which is what `| bash` gets.
BASH = os.environ.get("FLEXILE_TEST_BASH", "/bin/bash")


def make_extension_zip(version, bundle_id=BUNDLE_ID):
    """A small stand-in for the signed release: the real zip is the ZXP, rooted at the extension."""
    manifest = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<ExtensionManifest Version="8.0" ExtensionBundleId="{bundle_id}" '
        f'ExtensionBundleVersion="{version}" ExtensionBundleName="Flexile"></ExtensionManifest>\n'
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("CSXS/manifest.xml", manifest)
        archive.writestr("META-INF/signatures.xml", "<signatures/>")
        archive.writestr("index.html", f"<html>{version}</html>")
        archive.writestr("node_modules/dep/package.json", "{}")
    return buffer.getvalue()


def write_extension(folder, version, bundle_id=BUNDLE_ID):
    with zipfile.ZipFile(io.BytesIO(make_extension_zip(version, bundle_id))) as archive:
        archive.extractall(folder)


def installed_version(folder):
    with open(os.path.join(folder, "CSXS", "manifest.xml"), encoding="utf-8") as manifest:
        text = manifest.read()
    return text.split('ExtensionBundleVersion="')[1].split('"')[0]


class FakeServer:
    """Serves the scripts, /api/product/latest/flexile, the zip, and records PostHog captures."""

    def __init__(self):
        self.latest = None  # dict, or None for a 500
        self.zip_bytes = b""
        self.zip_status = 200
        self.events = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send(self, status, body, content_type):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path in ("/install.sh", "/install.ps1"):
                    with open(os.path.join(ROOT, self.path.lstrip("/")), "rb") as script:
                        self.send(200, script.read(), "text/plain; charset=utf-8")
                elif self.path == "/api/product/latest/flexile":
                    if server.latest is None:
                        self.send(500, b"{}", "application/json")
                    else:
                        self.send(200, json.dumps(server.latest).encode(), "application/json")
                elif self.path.startswith("/api/product/file/flexile/"):
                    self.send(server.zip_status, server.zip_bytes if server.zip_status == 200 else b"", "application/zip")
                else:
                    self.send(404, b"", "text/plain")

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.path == "/i/v0/e/":
                    server.events.append(json.loads(body))
                self.send(200, b"{}", "application/json")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def release(self, version, sha256="auto"):
        self.zip_bytes = make_extension_zip(version)
        self.zip_status = 200
        digest = hashlib.sha256(self.zip_bytes).hexdigest() if sha256 == "auto" else sha256
        self.latest = {"name": "flexile", "version": version, "fileType": "zip", "fileSize": len(self.zip_bytes), "sha256": digest}

    def stop(self):
        self.httpd.shutdown()


def shells():
    wanted = os.environ.get("FLEXILE_TEST_SHELLS")
    if wanted:
        return wanted.split(",")
    return ["powershell", "pwsh"] if IS_WINDOWS else ["bash"]


class InstallScriptTests(unittest.TestCase):
    shell = "bash"

    @classmethod
    def setUpClass(cls):
        cls.server = FakeServer()

    @classmethod
    def tearDownClass(cls):
        cls.server.stop()

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="flexile-test-")
        self.addCleanup(shutil.rmtree, self.home, True)
        if self.shell == "bash":
            self.ext_dir = os.path.join(self.home, "Library", "Application Support", "Adobe", "CEP", "extensions")
        else:
            self.ext_dir = os.path.join(self.home, "Adobe", "CEP", "extensions")
        self.system_dir = os.path.join(self.home, "system-extensions")
        self.server.events.clear()

    def run_installer(self, telemetry=True):
        env = dict(os.environ)
        env.update(
            FLEXILE_API_BASE=self.server.url,
            FLEXILE_TELEMETRY_URL=self.server.url + "/i/v0/e/",
            FLEXILE_SYSTEM_EXTENSIONS_DIR=self.system_dir,
            NO_COLOR="1",
        )
        env.pop("FLEXILE_NO_TELEMETRY", None)
        if not telemetry:
            env["FLEXILE_NO_TELEMETRY"] = "1"
        if self.shell == "bash":
            env["HOME"] = self.home
            command = ["bash", "-c", f"curl -fsSL {self.server.url}/install.sh | {BASH}"]
        else:
            env["APPDATA"] = self.home
            command = [self.shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", f"irm {self.server.url}/install.ps1 | iex"]
        result = subprocess.run(command, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
        output = result.stdout + result.stderr
        lines = [line for line in output.splitlines() if line.strip()]
        self.assertLessEqual(len(lines), 6, output)
        self.assertNotIn("Exception", output)
        self.assertNotIn("at line", output)
        return output

    def entries(self):
        return sorted(os.listdir(self.ext_dir)) if os.path.isdir(self.ext_dir) else []

    def make_link(self, link, target):
        if IS_WINDOWS:
            subprocess.run(["cmd", "/c", "mklink", "/J", link, target], check=True, capture_output=True)
        else:
            os.symlink(target, link)

    def test_fresh_install(self):
        self.server.release("1.2.0")
        output = self.run_installer()

        self.assertIn("Downloaded Flexile 1.2.0", output)
        self.assertIn("Installed", output)
        self.assertIn("Window", output)
        self.assertEqual(self.entries(), [BUNDLE_ID])
        folder = os.path.join(self.ext_dir, BUNDLE_ID)
        self.assertEqual(installed_version(folder), "1.2.0")
        self.assertTrue(os.path.isfile(os.path.join(folder, "META-INF", "signatures.xml")))

        self.assertEqual(len(self.server.events), 1)
        event = self.server.events[0]
        self.assertEqual(event["event"], "install_script_completed")
        self.assertEqual(event["properties"]["version"], "1.2.0")
        self.assertEqual(event["properties"]["os"], "windows" if IS_WINDOWS else "macos")
        self.assertFalse(event["properties"]["$process_person_profile"])
        self.assertTrue(event["distinct_id"].startswith("install-"))

    def test_reinstall_replaces_old_versions_and_keeps_other_extensions(self):
        os.makedirs(self.ext_dir)
        write_extension(os.path.join(self.ext_dir, BUNDLE_ID), "1.0.0")
        write_extension(os.path.join(self.ext_dir, BUNDLE_ID + "-1_1_0"), "1.1.0")
        write_extension(os.path.join(self.ext_dir, "flexile_0_17_0"), "0.17.0")
        write_extension(os.path.join(self.ext_dir, "com.other.extension"), "3.0.0", bundle_id="com.other.extension")
        dev_build = os.path.join(self.home, "dev-build")
        write_extension(dev_build, "9.9.9")
        self.make_link(os.path.join(self.ext_dir, "flexile-dev-link"), dev_build)

        self.server.release("1.2.0")
        output = self.run_installer()

        self.assertIn("Installed", output)
        self.assertEqual(self.entries(), sorted([BUNDLE_ID, "com.other.extension"]))
        self.assertEqual(installed_version(os.path.join(self.ext_dir, BUNDLE_ID)), "1.2.0")
        self.assertEqual(installed_version(os.path.join(self.ext_dir, "com.other.extension")), "3.0.0")
        self.assertEqual(installed_version(dev_build), "9.9.9", "the link target must survive")

    def test_checksum_mismatch_installs_nothing(self):
        os.makedirs(self.ext_dir)
        write_extension(os.path.join(self.ext_dir, BUNDLE_ID), "1.0.0")
        self.server.release("1.2.0", sha256="0" * 64)
        output = self.run_installer()

        self.assertIn("checksum mismatch", output)
        self.assertIn("flexile.io/blog/how-to-install-flexile", output)
        self.assertEqual(self.entries(), [BUNDLE_ID])
        self.assertEqual(installed_version(os.path.join(self.ext_dir, BUNDLE_ID)), "1.0.0")
        self.assertEqual([e["event"] for e in self.server.events], ["install_script_failed"])
        self.assertEqual(self.server.events[0]["properties"]["error_code"], "checksum_mismatch")

    def test_missing_checksum_installs_nothing(self):
        self.server.release("1.2.0", sha256=None)
        output = self.run_installer()

        self.assertIn("no checksum", output)
        self.assertEqual(self.entries(), [])
        self.assertEqual(self.server.events[0]["properties"]["error_code"], "checksum_missing")

    def test_download_failure(self):
        self.server.release("1.2.0")
        self.server.zip_status = 404
        output = self.run_installer()

        self.assertIn("download didn't finish", output)
        self.assertEqual(self.entries(), [])
        self.assertEqual(self.server.events[0]["properties"]["error_code"], "download_failed")

    def test_api_down(self):
        self.server.latest = None
        output = self.run_installer()

        self.assertIn("Couldn't reach flexile.io", output)
        self.assertEqual(self.server.events[0]["properties"]["error_code"], "metadata_failed")

    def test_warns_about_machine_wide_copy(self):
        write_extension(os.path.join(self.system_dir, "flexile"), "0.16.0")
        self.server.release("1.2.0")
        output = self.run_installer()

        self.assertIn("for all users", output)
        self.assertEqual(installed_version(os.path.join(self.system_dir, "flexile")), "0.16.0", "never touched")

    def test_no_telemetry_opt_out(self):
        self.server.release("1.2.0")
        output = self.run_installer(telemetry=False)

        self.assertIn("Installed", output)
        self.assertEqual(self.server.events, [])


def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite()
    for shell in shells():
        cls = type(f"InstallScriptTests_{shell}", (InstallScriptTests,), {"shell": shell})
        suite.addTests(loader.loadTestsFromTestCase(cls))
    return suite


if __name__ == "__main__":
    unittest.main(verbosity=2)
