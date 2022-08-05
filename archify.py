import os
import subprocess
import sys
import tempfile
import time
import argparse

LIPO = "/usr/bin/lipo"
FILE = "/usr/bin/file"
LDID = ""


def clean_bin(bin, arch):
    subprocess.check_output(
        [
            LIPO,
            "-thin",
            arch,
            bin,
            "-output",
            bin + f".{arch}",
        ]
    )
    os.remove(bin)
    os.rename(bin + f".{arch}", bin)


def sign_bin(bin, no_ent):
    entitlements = ""
    try:
        entitlements = (
            subprocess.check_output([LDID, "-e", bin], stderr=sys.stderr)
            .decode()
            .strip()
        )
    except subprocess.CalledProcessError:
        pass

    if not entitlements or no_ent:
        status = subprocess.call([LDID, "-S", bin])
        if status != 0:
            print("Failed to sign %s" % bin)
        return

    fd, tmp_file = tempfile.mkstemp()
    with open(tmp_file, "w") as f:
        f.write(entitlements)

    status = subprocess.call([LDID, f"-S{tmp_file}", bin])
    os.close(fd)
    os.remove(tmp_file)

    if status != 0:
        print("Failed to sign %s" % bin)


def duplicate_app(app_dir, output_dir):
    if not os.path.exists(output_dir):
        print("Output dir does not exist: %s" % output_dir)
        return

    os.makedirs(os.path.join(output_dir, os.path.split(app_dir)[-1]), exist_ok=True)
    rsync_p = subprocess.Popen(
        [
            "rsync",
            "-r",
            "-v",
            "-aHz",
            f"{app_dir}",
            f"{output_dir}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    last = time.time()
    lines = 0
    total_time = 0
    for line in iter(lambda: rsync_p.stdout.readline(), b""):
        lines += 1
        total_time += time.time() - last
        last = time.time()
        sys.stdout.write(
            "\r" + str(round(lines / total_time, 2)) + " files/sec; " + str(lines) + " "
        )

    return os.path.join(output_dir, os.path.split(app_dir)[-1])


def is_mach(path):
    if os.path.islink(path):
        return False

    if not os.access(path, os.X_OK):
        return False

    output = subprocess.check_output([FILE, "--mime-type", path])
    return output.split()[-1].decode() == "application/x-mach-binary"


def is_universal(path, target_arch):
    output = subprocess.check_output([LIPO, "-info", path])
    output = output.decode().split(":")[-1].strip()
    archs = output.split()

    if len(archs) == 1:
        return False

    if target_arch in archs:
        return target_arch

    if target_arch == "arm64":
        if "arm64e" in archs:
            return "arm64e"

    if target_arch == "arm64e":
        if "arm64" in archs:
            return "arm64"

    if target_arch != "i386" and "i386" in archs:
        if target_arch == "x86_64" and "x86_64" in archs:
            return "x86_64"

        if target_arch == "arm64e" or target_arch == "arm64":
            if "x86_64" in archs:
                return "x86_64"

            if "arm64e" in archs:
                return "arm64e"

            if "arm64" in archs:
                return "arm64"

    return False


def main():
    global LDID
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-app",
        "--app_dir",
        nargs="+",
        type=str,
        required=True,
        help="The app to armify",
    )
    parser.add_argument(
        "-o",
        "--output_dir",
        type=str,
        default=os.getcwd(),
        help="Where the copy of the app is stored; defaults to working directory",
    )
    parser.add_argument(
        "-arch",
        "--arch",
        type=str,
        default=os.uname().machine,
        help="The architecture to archify to; default: python's architecture",
    )
    parser.add_argument(
        "-ld", "--ldid", type=str, help="The path to ldid for resigning the binaries"
    )

    parser.add_argument(
        "-Ns",
        "--no_sign",
        help="Do not sign the binaries with ldid",
        action="store_true",
    )

    parser.add_argument(
        "-Ne",
        "--no_entitleemtns",
        help="Do not sign the binaries with original entitlements with ldid",
        action="store_true",
    )

    args = parser.parse_args()
    app_dir = sorted(list(set(args.app_dir)))

    for dir in app_dir:
        if not os.path.exists(dir):
            print("App dir does not exist: %s" % dir)
            return

        output_dir = args.output_dir
        target_arch = args.arch

        if os.path.exists("/usr/local/bin/ldid"):
            LDID = "/usr/local/bin/ldid"

        if args.ldid:
            if os.path.exists(args.ldid):
                LDID = args.ldid
            else:
                print("Specified ldid not found")
                if LDID:
                    print("Using: %s" % LDID, "\n")
                else:
                    print("No ldid found\n")

        print("\nCreating a copy at", output_dir, f"({dir.split('/')[-1]})")

        dir = duplicate_app(dir, output_dir)

        print("\nExtracting the target binaries")

        for root, dirs, files in os.walk(dir):
            for file in files:
                file = os.path.join(root, file)
                if is_mach(file):
                    arch = is_universal(file, target_arch)
                    if arch:
                        print("Cleaning %s" % file)
                        clean_bin(file, arch)
                        if LDID and not args.no_sign:
                            print("Signing %s" % file)
                            sign_bin(file, args.no_entitleemtns)


if __name__ == "__main__":
    main()
