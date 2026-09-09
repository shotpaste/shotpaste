"""Exercise installer release selection without downloading or installing an app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Uses the macOS JavaScript automation runtime")
class InstallerArchitectureTests(unittest.TestCase):
    def run_installer(self, architecture, releases, version=None):
        with tempfile.TemporaryDirectory(prefix="shotpaste-installer-test-") as directory:
            root = Path(directory)
            # Stop at the download boundary; never mount or copy user data.
            scripts = {
                "uname": '#!/bin/bash\nif [[ "$1" == "-s" ]]; then echo Darwin; else echo "$TEST_ARCH"; fi\n',
                "curl": '#!/bin/bash\nif [[ "$*" == *api.github.com* ]]; then printf "%s" "$TEST_RELEASES"; else printf "TEST_DOWNLOAD:%s\\n" "$*"; exit 22; fi\n',
            }
            for name, content in scripts.items():
                target = root / name
                target.write_text(content)
                target.chmod(0o755)
            env = {**os.environ, "PATH": f"{root}:/usr/bin:/bin:/usr/sbin:/sbin",
                   "TEST_ARCH": architecture, "TEST_RELEASES": json.dumps(releases), "NO_COLOR": "1"}
            env.pop("VERSION", None)
            if version is not None:
                env["VERSION"] = version
            result = subprocess.run(["/bin/bash", str(Path(__file__).with_name("install.sh"))],
                                    env=env, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            return result.stdout + result.stderr

    @staticmethod
    def release(version, architecture, **overrides):
        tag = f"macos-v{version}"
        name = f"ShotPaste-v{version}-macOS-{architecture}.dmg"
        return {"tag_name": tag, "draft": False, "prerelease": False,
                "assets": [{"name": name, "state": "uploaded", "size": 100,
                            "browser_download_url": f"https://github.com/shotpaste/shotpaste/releases/download/{tag}/{name}"}],
                **overrides}

    def test_intel_uses_latest_matching_package_and_skips_drafts(self):
        output = self.run_installer("x86_64", [self.release("3.0.0", "arm64"),
            self.release("2.0.0", "x86_64", draft=True), self.release("1.9.0", "x86_64")])
        self.assertIn("TEST_DOWNLOAD:", output)
        self.assertIn("ShotPaste-v1.9.0-macOS-x86_64.dmg", output)
        self.assertNotIn("macOS-arm64.dmg", output)

    def test_arm_keeps_existing_package_convention(self):
        output = self.run_installer("arm64", [self.release("2.0.0", "x86_64"), self.release("1.9.0", "arm64")])
        self.assertIn("ShotPaste-v1.9.0-macOS-arm64.dmg", output)

    def test_missing_intel_asset_does_not_download_arm(self):
        output = self.run_installer("x86_64", [self.release("2.0.0", "arm64")])
        self.assertIn("No published macOS release with a x86_64 package", output)
        self.assertNotIn("TEST_DOWNLOAD:", output)

    def test_explicit_version_selects_intel_filename(self):
        output = self.run_installer("x86_64", [], "macos-v1.2.3")
        self.assertIn("ShotPaste-v1.2.3-macOS-x86_64.dmg", output)


if __name__ == "__main__":
    unittest.main()
