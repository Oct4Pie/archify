import base64
import json
import plistlib
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class UpdateConfigurationTests(unittest.TestCase):
    def test_sparkle_info_plist_is_securely_configured(self):
        with (ROOT / "archify" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(
            info["SUFeedURL"],
            "https://raw.githubusercontent.com/Oct4Pie/archify/main/appcast.xml",
        )
        self.assertTrue(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertTrue(info["SURequireSignedFeed"])

        public_key = base64.b64decode(
            info["SUPublicEDKey"],
            validate=True,
        )
        self.assertEqual(len(public_key), 32)

    def test_bootstrap_appcast_is_signed_and_valid_xml_shape(self):
        appcast = (ROOT / "appcast.xml").read_text(encoding="utf-8")
        self.assertIn("<rss", appcast)
        self.assertIn("<channel>", appcast)
        self.assertIn("sparkle-signatures:", appcast)
        self.assertIn("edSignature:", appcast)

    def test_sparkle_package_is_pinned(self):
        resolved = (
            ROOT
            / "archify.xcodeproj"
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved"
        )
        data = json.loads(resolved.read_text(encoding="utf-8"))
        sparkle = next(
            pin
            for pin in data["pins"]
            if pin["identity"] == "sparkle"
        )
        self.assertEqual(sparkle["state"]["version"], "2.10.0")

    def test_privileged_helper_trust_defaults_remain_team_bound(self):
        with (ROOT / "archify" / "Info.plist").open("rb") as handle:
            app_info = plistlib.load(handle)
        with (
            ROOT / "archify" / "archifyhelper" / "Info.plist"
        ).open("rb") as handle:
            helper_info = plistlib.load(handle)

        self.assertEqual(
            app_info["SMPrivilegedExecutables"][
                "com.oct4pie.archifyhelper"
            ],
            "$(ARCHIFY_HELPER_CODE_REQUIREMENT)",
        )
        self.assertEqual(
            helper_info["SMAuthorizedClients"][0],
            "$(ARCHIFY_CLIENT_CODE_REQUIREMENT)",
        )

        project = (
            ROOT / "archify.xcodeproj" / "project.pbxproj"
        ).read_text(encoding="utf-8")
        client_requirement = (
            'ARCHIFY_CLIENT_CODE_REQUIREMENT = '
            '"anchor apple generic and identifier '
            '\\"com.oct4pie.archify\\" and certificate '
            'leaf[subject.OU] = \\"9827C97648\\"";'
        )
        helper_requirement = (
            'ARCHIFY_HELPER_CODE_REQUIREMENT = '
            '"anchor apple generic and identifier '
            '\\"com.oct4pie.archifyhelper\\" and certificate '
            'leaf[subject.OU] = \\"9827C97648\\"";'
        )

        helper_dir = ROOT / "archify" / "archifyhelper"
        with (helper_dir / "com.oct4pie.archify.helper.plist").open("rb") as handle:
            daemon = plistlib.load(handle)
        with (helper_dir / "com.oct4pie.archifyhelper.legacy.plist").open("rb") as handle:
            legacy = plistlib.load(handle)
        # Distinct labels let the SMAppService helper run while a legacy
        # SMJobBless helper is still loaded, so migration needs no restart.
        self.assertEqual(daemon["Label"], "com.oct4pie.archify.helper")
        self.assertEqual(list(daemon["MachServices"]), ["com.oct4pie.archify.helper"])
        self.assertEqual(legacy["Label"], "com.oct4pie.archifyhelper")
        self.assertNotEqual(daemon["Label"], legacy["Label"])
        self.assertEqual(daemon["AssociatedBundleIdentifiers"], ["com.oct4pie.archify"])

        self.assertEqual(project.count(client_requirement), 2)
        self.assertEqual(project.count(helper_requirement), 2)
        self.assertNotIn(
            'ARCHIFY_CLIENT_CODE_REQUIREMENT = "identifier',
            project,
        )
        self.assertNotIn(
            'ARCHIFY_HELPER_CODE_REQUIREMENT = "identifier',
            project,
        )

    def test_release_version_and_signing_configuration(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "project-version.py"),
                "--format",
                "json",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        version = json.loads(result.stdout)
        self.assertEqual(version, {"version": "1.5.0", "build": "10"})

        project = (
            ROOT / "archify.xcodeproj" / "project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertEqual(
            project.count('CODE_SIGN_IDENTITY = "Developer ID Application";'),
            2,
        )
        self.assertEqual(
            project.count(
                '"CODE_SIGN_IDENTITY[sdk=macosx*]" = '
                '"Developer ID Application";'
            ),
            2,
        )
        self.assertNotIn("3rd Party Mac Developer Application", project)
        self.assertEqual(
            project.count("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;"),
            2,
        )

        release_marker = (
            "B2C0EC122C1AB05400132B38 /* Release */"
        )
        release_block = project.split(release_marker, 1)[1].split(
            "name = Release;",
            1,
        )[0]
        self.assertIn("ONLY_ACTIVE_ARCH = NO;", release_block)
        self.assertIn("MARKETING_VERSION = 1.5.0;", release_block)
        self.assertIn("CURRENT_PROJECT_VERSION = 10;", release_block)

        with (
            ROOT
            / "archify"
            / "archifyhelper"
            / "archifyhelper.entitlements"
        ).open("rb") as handle:
            helper_entitlements = plistlib.load(handle)
        self.assertEqual(helper_entitlements, {})

        release_script = (
            ROOT / "scripts" / "build-release.sh"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
            release_script,
        )
        self.assertIn("--timestamp", release_script)
        self.assertIn("SPARKLE_UPDATER", release_script)
        self.assertIn("SPARKLE_DOWNLOADER", release_script)
        self.assertIn("SPARKLE_INSTALLER", release_script)
        self.assertIn("notary-result.json", release_script)
        self.assertIn('NOTARY_STATUS', release_script)


if __name__ == "__main__":
    unittest.main()
