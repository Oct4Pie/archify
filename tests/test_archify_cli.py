import hashlib
import importlib.util
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "archify_cli",
    ROOT / "archify.py",
)
archify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archify)


class ArchifyCLITests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="archify-cli-tests-"
        )
        self.root = Path(self.tempdir.name)

    def tearDown(self):
        self.tempdir.cleanup()

    def make_app(self, name="Test.app"):
        app = self.root / name
        (app / "Contents" / "MacOS").mkdir(parents=True)
        return app

    def test_is_mach_uses_header_not_executable_bit(self):
        binary = self.root / "binary"
        binary.write_bytes(
            b"\xca\xfe\xba\xbe" + b"payload"
        )
        binary.chmod(0o644)
        self.assertTrue(
            archify.is_mach(str(binary))
        )

        text = self.root / "text"
        text.write_text("hello", encoding="utf-8")
        self.assertFalse(
            archify.is_mach(str(text))
        )

    def test_preferred_architecture_matches_rules(self):
        self.assertEqual(
            archify.preferred_architecture(
                ["x86_64", "arm64"],
                "arm64",
            ),
            "arm64",
        )
        self.assertEqual(
            archify.preferred_architecture(
                ["x86_64", "arm64e"],
                "arm64",
            ),
            "arm64e",
        )
        self.assertEqual(
            archify.preferred_architecture(
                ["i386", "x86_64"],
                "arm64",
            ),
            "x86_64",
        )
        self.assertIsNone(
            archify.preferred_architecture(
                ["arm64"],
                "arm64",
            )
        )
        self.assertEqual(
            archify.preferred_architecture(
                ["x86_64", "arm64e.x1"],
                "arm64",
            ),
            "arm64e.x1",
        )
        self.assertEqual(
            archify.preferred_architecture(
                ["arm64", "x86_64h"],
                "x86_64",
            ),
            "x86_64h",
        )

    def test_mach_parser_handles_modern_fat_slices_without_lipo(self):
        binary = self.root / "fat-binary"
        data = bytearray(b"\xca\xfe\xba\xbe")
        data += struct.pack(">I", 3)
        data += struct.pack(
            ">IIIII",
            0x01000007,
            3,
            0x1000,
            0x2000,
            12,
        )
        data += struct.pack(
            ">IIIII",
            0x0100000C,
            0x80000002,
            0x3000,
            0x4000,
            12,
        )
        data += struct.pack(
            ">IIIII",
            0x0100000C,
            0x8000000C,
            0x7000,
            0x5000,
            12,
        )
        binary.write_bytes(data)

        with mock.patch.object(
            archify,
            "run_process",
            side_effect=AssertionError(
                "architecture inspection must not spawn lipo"
            ),
        ):
            self.assertEqual(
                archify.get_mach_slices(str(binary)),
                [
                    ("x86_64", 0x2000),
                    ("arm64e", 0x4000),
                    ("arm64e.x1", 0x5000),
                ],
            )
            self.assertEqual(
                archify.get_architectures(str(binary)),
                ["x86_64", "arm64e", "arm64e.x1"],
            )

    def test_mach_parser_handles_fat64_and_rejects_symlink(self):
        binary = self.root / "fat64"
        data = bytearray(b"\xca\xfe\xba\xbf")
        data += struct.pack(">I", 2)
        data += struct.pack(
            ">IIQQII",
            0x01000007,
            8,
            0x100000000,
            0x12345,
            14,
            0,
        )
        data += struct.pack(
            ">IIQQII",
            0x0100000C,
            2,
            0x200000000,
            0x23456,
            14,
            0,
        )
        binary.write_bytes(data)
        link = self.root / "fat64-link"
        link.symlink_to(binary)

        self.assertEqual(
            archify.get_architectures(str(binary)),
            ["x86_64h", "arm64e"],
        )
        self.assertIsNone(
            archify.get_architectures(str(link))
        )

    def test_machine_architecture_reports_physical_apple_silicon(self):
        if os.uname().sysname != "Darwin":
            self.skipTest("macOS-specific host architecture behavior")

        result = archify.run_process(
            ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"],
            stdout=archify.subprocess.PIPE,
            stderr=archify.subprocess.DEVNULL,
            text=True,
        )
        if result.returncode != 0 or result.stdout.strip() != "1":
            self.skipTest("not running on Apple Silicon hardware")

        self.assertEqual(
            archify.machine_architecture(),
            "arm64",
        )

    def test_duplicate_app_copies_and_refuses_collision(self):
        app = self.make_app()
        runner = (
            app / "Contents" / "MacOS" / "Runner"
        )
        runner.write_bytes(b"payload")
        output = self.root / "Output"
        output.mkdir()

        copied = Path(
            archify.duplicate_app(
                str(app),
                str(output),
            )
        )
        self.assertEqual(
            (
                copied
                / "Contents"
                / "MacOS"
                / "Runner"
            ).read_bytes(),
            b"payload",
        )
        with self.assertRaises(RuntimeError):
            archify.duplicate_app(
                str(app),
                str(output),
            )

    def test_duplicate_app_cleans_partial_on_failure(self):
        app = self.make_app()
        output = self.root / "Output"
        output.mkdir()
        fake_ditto = self.root / "fake-ditto"
        fake_ditto.write_text(
            "#!/bin/sh\n"
            "for arg in \"$@\"; do dest=\"$arg\"; done\n"
            "mkdir -p \"$dest\"\n"
            "echo partial > \"$dest/partial\"\n"
            "exit 42\n",
            encoding="utf-8",
        )
        fake_ditto.chmod(0o755)

        with mock.patch.object(
            archify,
            "DITTO",
            str(fake_ditto),
        ):
            with self.assertRaises(RuntimeError):
                archify.duplicate_app(
                    str(app),
                    str(output),
                )

        self.assertFalse(
            (output / app.name).exists()
        )
        self.assertEqual(list(output.iterdir()), [])

    def test_duplicate_app_never_merges_into_or_deletes_a_raced_destination(self):
        app = self.make_app()
        output = self.root / "Output"
        output.mkdir()
        planted = output / app.name
        for status in (0, 42):
            fake_ditto = self.root / f"fake-ditto-{status}"
            fake_ditto.write_text(
                "#!/bin/sh\n"
                "for arg in \"$@\"; do dest=\"$arg\"; done\n"
                f"mkdir -p \"$dest\" \"{planted}\"\n"
                f"echo other > \"{planted}/other\"\n"
                f"exit {status}\n",
                encoding="utf-8",
            )
            fake_ditto.chmod(0o755)

            with mock.patch.object(archify, "DITTO", str(fake_ditto)):
                with self.assertRaises(RuntimeError):
                    archify.duplicate_app(str(app), str(output))

            self.assertEqual(sorted(p.name for p in planted.iterdir()), ["other"])
            self.assertEqual(
                (planted / "other").read_text(encoding="utf-8"), "other\n"
            )
            self.assertEqual([p.name for p in output.iterdir()], [app.name])
            shutil.rmtree(planted)

    def test_duplicate_app_refuses_folders_other_users_can_change(self):
        app = self.make_app()
        output = self.root / "Output"
        output.mkdir()
        output.chmod(0o777)
        with self.assertRaises(RuntimeError):
            archify.duplicate_app(str(app), str(output))
        self.assertEqual(list(output.iterdir()), [])

        output.chmod(0o755)
        subprocess.run(
            ["/bin/chmod", "+a", "everyone allow add_file,delete_child", str(output)],
            check=True,
        )
        with self.assertRaises(RuntimeError):
            archify.duplicate_app(str(app), str(output))
        subprocess.run(["/bin/chmod", "-N", str(output)], check=True)

        # Sticky folders such as /tmp are fine: others cannot rename our entries.
        output.chmod(0o1777)
        archify.duplicate_app(str(app), str(output))
        self.assertTrue((output / app.name).is_dir())

    def test_log_is_never_written_through_a_link(self):
        target = self.root / "target.txt"
        target.write_text("keep", encoding="utf-8")
        archify.Log.log_buffer = ["message"]
        try:
            fifo = self.root / "fifo-log.txt"
            os.mkfifo(fifo)
            with self.assertRaises(OSError):
                archify.Log.save_log_to_file(str(fifo))

            symlink = self.root / "symlink-log.txt"
            symlink.symlink_to(target)
            with self.assertRaises(OSError):
                archify.Log.save_log_to_file(str(symlink))

            hardlink = self.root / "hardlink-log.txt"
            os.link(target, hardlink)
            with self.assertRaises(OSError):
                archify.Log.save_log_to_file(str(hardlink))
            self.assertEqual(target.read_text(encoding="utf-8"), "keep")

            log = self.root / "process_log.txt"
            log.write_text("old contents that are longer", encoding="utf-8")
            archify.Log.save_log_to_file(str(log))
            self.assertEqual(log.read_text(encoding="utf-8"), "message\n")
        finally:
            archify.Log.log_buffer = []

    def test_refuses_untrusted_output_folder_before_writing_anything(self):
        output = self.root / "Output"
        output.mkdir()
        output.chmod(0o777)
        with mock.patch.object(archify, "parse_arguments") as parse, \
                mock.patch.object(archify, "duplicate_app") as duplicate:
            parse.return_value = mock.Mock(
                app_dir=[str(self.make_app())], output_dir=str(output)
            )
            self.assertEqual(archify.main(), 1)
            duplicate.assert_not_called()
        self.assertEqual(list(output.iterdir()), [])

    def test_refuses_to_run_as_root(self):
        with mock.patch.object(archify.os, "geteuid", return_value=0), \
                mock.patch.object(archify, "parse_arguments") as parse, \
                mock.patch.object(archify, "duplicate_app") as duplicate:
            parse.return_value = mock.Mock(
                app_dir=[str(self.make_app())], output_dir=str(self.root)
            )
            self.assertEqual(archify.main(), 1)
            duplicate.assert_not_called()

    def test_transactional_thinning_preserves_signature(self):
        app = self.make_app()
        runner = (
            app / "Contents" / "MacOS" / "Runner"
        )
        shutil.copyfile("/usr/bin/true", runner)
        runner.chmod(0o755)
        info = app / "Contents" / "Info.plist"
        info.write_bytes(
            archify.plistlib.dumps(
                {
                    "CFBundleExecutable": "Runner",
                    "CFBundleIdentifier": "test.archify.cli",
                    "CFBundlePackageType": "APPL",
                }
            )
        )
        sign_result = archify.run_process(
            [
                archify.CODESIGN,
                "--force",
                "--deep",
                "--sign",
                "-",
                str(app),
            ],
            stdout=archify.subprocess.DEVNULL,
            stderr=archify.subprocess.DEVNULL,
        )
        self.assertEqual(sign_result.returncode, 0)

        before_arches = archify.get_architectures(
            str(runner)
        )
        target = archify.machine_architecture()
        expected = archify.preferred_architecture(
            before_arches,
            target,
        )
        self.assertIsNotNone(expected)
        self.assertTrue(
            archify.has_valid_code_signature(
                str(app),
                deep=True,
            )
        )

        changed = archify.thin_app_transactionally(
            str(app),
            target,
        )

        self.assertEqual(
            changed,
            [str(runner.resolve())],
        )
        self.assertEqual(
            archify.get_architectures(
                str(runner)
            ),
            [expected],
        )
        self.assertTrue(
            archify.has_valid_code_signature(
                str(app),
                deep=True,
            )
        )
        self.assertFalse(
            any(
                child.name.startswith(
                    ".archify-"
                )
                for child in runner.parent.iterdir()
            )
        )
        self.assertFalse(
            any(
                child.name.startswith(
                    ".archify-transaction-"
                )
                for child in app.parent.iterdir()
            )
        )

    def test_thinning_stores_binaries_compressed(self):
        app = self.make_app()
        runner = app / "Contents" / "MacOS" / "Runner"
        shutil.copyfile("/usr/bin/true", runner)
        runner.chmod(0o755)

        archify.thin_app_transactionally(str(app), archify.machine_architecture())

        self.assertTrue(os.lstat(runner).st_flags & archify.UF_COMPRESSED)
        self.assertEqual(len(archify.get_architectures(str(runner))), 1)
        self.assertEqual(os.lstat(runner).st_mode & 0o777, 0o755)

    def test_thinning_without_compression_leaves_plain_files(self):
        app = self.make_app()
        runner = app / "Contents" / "MacOS" / "Runner"
        shutil.copyfile("/usr/bin/true", runner)

        archify.thin_app_transactionally(
            str(app),
            archify.machine_architecture(),
            compress=False,
        )

        self.assertFalse(os.lstat(runner).st_flags & archify.UF_COMPRESSED)

    def test_compress_file_reads_back_identically(self):
        payload = bytes(
            (index if index % 251 == 0 else index % 7) & 0xFF
            for index in range(300 * 1024)
        )
        path = self.root / "payload"
        path.write_bytes(payload)
        os.chmod(path, 0o751)
        os.utime(path, (1_000_000, 1_000_000))

        self.assertEqual(archify.compress_file(str(path)), "compressed")
        info = os.lstat(path)
        self.assertTrue(info.st_flags & archify.UF_COMPRESSED)
        self.assertEqual(path.read_bytes(), payload)
        self.assertEqual(info.st_mode & 0o777, 0o751)
        self.assertEqual(int(info.st_mtime), 1_000_000)
        self.assertLess(info.st_blocks * 512, len(payload) // 2)
        self.assertEqual(archify.compress_file(str(path)), "unchanged")

    def test_compress_file_leaves_incompressible_and_tiny_files(self):
        noise = os.urandom(200 * 1024)
        random_path = self.root / "random"
        random_path.write_bytes(noise)
        self.assertEqual(archify.compress_file(str(random_path)), "unchanged")
        self.assertEqual(random_path.read_bytes(), noise)

        tiny = self.root / "tiny"
        tiny.write_bytes(b"hello")
        self.assertEqual(archify.compress_file(str(tiny)), "unchanged")
        self.assertEqual(tiny.read_bytes(), b"hello")

    def test_compress_file_keeps_resource_forks_and_hard_links(self):
        payload = bytes(index % 7 for index in range(300 * 1024))
        forked = self.root / "forked"
        forked.write_bytes(payload)
        archify.subprocess.run(
            ["/usr/bin/xattr", "-w", "com.apple.ResourceFork", "resource data", str(forked)],
            check=True,
        )
        self.assertEqual(archify.compress_file(str(forked)), "unchanged")
        fork = archify.subprocess.run(
            ["/usr/bin/xattr", "-p", "com.apple.ResourceFork", str(forked)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(fork.stdout.strip(), "resource data")

        linked = self.root / "linked"
        linked.write_bytes(payload)
        os.link(linked, self.root / "other-name")
        self.assertEqual(archify.compress_file(str(linked)), "unchanged")
        self.assertFalse(os.lstat(linked).st_flags & archify.UF_COMPRESSED)

    def test_failed_install_and_restore_keeps_the_original(self):
        app = self.make_app()
        runner = app / "Contents" / "MacOS" / "Runner"
        shutil.copyfile("/usr/bin/true", runner)
        original = runner.read_bytes()
        real_replace = os.replace

        # Moving the original out succeeds; every later move fails, so the
        # only copy of the original is the backup in the transaction folder.
        def replace(source, destination):
            if Path(source).resolve() == runner.resolve():
                return real_replace(source, destination)
            raise OSError("simulated failure")

        with mock.patch.object(archify.os, "replace", side_effect=replace):
            with self.assertRaises(RuntimeError) as raised:
                archify.thin_app_transactionally(
                    str(app),
                    archify.machine_architecture(),
                )

        self.assertIn("Recovery data remains", str(raised.exception))
        backups = list(app.parent.glob(".archify-transaction-*/backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)

    def make_signed_app_with_sealed_resource(self):
        app = self.make_app()
        runner = app / "Contents" / "MacOS" / "Runner"
        shutil.copyfile("/usr/bin/true", runner)
        runner.chmod(0o755)
        resource = app / "Contents" / "Resources" / "addon.node"
        resource.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", resource)
        (app / "Contents" / "Info.plist").write_bytes(
            archify.plistlib.dumps(
                {
                    "CFBundleExecutable": "Runner",
                    "CFBundleIdentifier": "test.archify.cli",
                    "CFBundlePackageType": "APPL",
                }
            )
        )
        sign_result = archify.run_process(
            [archify.CODESIGN, "--force", "--sign", "-", str(app)],
            stdout=archify.subprocess.DEVNULL,
            stderr=archify.subprocess.DEVNULL,
        )
        self.assertEqual(sign_result.returncode, 0)
        return app, runner, resource

    def test_thinning_skips_binaries_sealed_as_resources(self):
        app, runner, resource = self.make_signed_app_with_sealed_resource()
        resource_before = resource.read_bytes()
        target = archify.machine_architecture()

        self.assertTrue(
            archify.SealedResourceIndex(app.resolve()).is_sealed_resource(
                str(resource.resolve())
            )
        )

        changed = archify.thin_app_transactionally(str(app), target)

        self.assertEqual(changed, [str(runner.resolve())])
        self.assertEqual(resource.read_bytes(), resource_before)
        self.assertTrue(
            archify.has_valid_code_signature(str(app), deep=True)
        )

    def test_thinning_for_resign_includes_sealed_resources(self):
        app, runner, resource = self.make_signed_app_with_sealed_resource()
        target = archify.machine_architecture()

        changed = archify.thin_app_transactionally(
            str(app),
            target,
            will_resign=True,
        )

        self.assertEqual(
            sorted(changed),
            sorted([str(runner.resolve()), str(resource.resolve())]),
        )
        self.assertEqual(
            len(archify.get_architectures(str(resource))),
            1,
        )

    def test_preparation_failure_leaves_originals(self):
        app = self.make_app()
        good = (
            app / "Contents" / "MacOS" / "Good"
        )
        fail = (
            app / "Contents" / "MacOS" / "Fail"
        )
        shutil.copyfile("/usr/bin/true", good)
        shutil.copyfile("/usr/bin/true", fail)
        good.chmod(0o755)
        fail.chmod(0o755)
        before = {
            good: hashlib.sha256(
                good.read_bytes()
            ).digest(),
            fail: hashlib.sha256(
                fail.read_bytes()
            ).digest(),
        }

        fake_lipo = self.root / "fake-lipo"
        fake_lipo.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = \"-archs\" ]; then "
            "exec /usr/bin/lipo \"$@\"; fi\n"
            "case \"$1\" in *Fail*) exit 42 ;; "
            "*) exec /usr/bin/lipo \"$@\" ;; esac\n",
            encoding="utf-8",
        )
        fake_lipo.chmod(0o755)

        with mock.patch.object(
            archify,
            "LIPO",
            str(fake_lipo),
        ):
            with self.assertRaises(RuntimeError):
                archify.thin_app_transactionally(
                    str(app),
                    archify.machine_architecture(),
                )

        self.assertEqual(
            hashlib.sha256(
                good.read_bytes()
            ).digest(),
            before[good],
        )
        self.assertEqual(
            hashlib.sha256(
                fail.read_bytes()
            ).digest(),
            before[fail],
        )
        self.assertFalse(
            any(
                child.name.startswith(
                    ".archify-"
                )
                for child in good.parent.iterdir()
            )
        )
        self.assertFalse(
            any(
                child.name.startswith(
                    ".archify-transaction-"
                )
                for child in app.parent.iterdir()
            )
        )


if __name__ == "__main__":
    unittest.main()
