import argparse
import ctypes
import errno
import os
import plistlib
import shutil
import signal
import stat
import struct
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

LIPO = "/usr/bin/lipo"
CODESIGN = "/usr/bin/codesign"
DITTO = "/usr/bin/ditto"
OPEN = "/usr/bin/open"
PS = "/bin/ps"
LDID = ""

MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce",  # MH_MAGIC
    b"\xce\xfa\xed\xfe",  # MH_CIGAM
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64
    b"\xcf\xfa\xed\xfe",  # MH_CIGAM_64
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC
    b"\xbe\xba\xfe\xca",  # FAT_CIGAM
    b"\xca\xfe\xba\xbf",  # FAT_MAGIC_64
    b"\xbf\xba\xfe\xca",  # FAT_CIGAM_64
}


class Log:
    log_buffer = []

    @staticmethod
    def append(message):
        Log.log_buffer.append(message)
        print(message)

    @staticmethod
    def save_log_to_file(file_path):
        # Never follow a link, or write through a hard link, planted at the
        # log's name.
        fd = os.open(
            file_path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
            | os.O_CLOEXEC,
            0o644,
        )
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise OSError(
                    errno.EEXIST,
                    "Refusing to overwrite an unexpected file",
                    file_path,
                )
            os.ftruncate(fd, 0)
        except BaseException:
            os.close(fd)
            raise
        with os.fdopen(fd, "w", encoding="utf-8") as log_file:
            for log_message in Log.log_buffer:
                log_file.write(log_message + "\n")


def run_process(arguments, **kwargs):
    return subprocess.run(arguments, check=False, **kwargs)


def is_mach(path):
    try:
        info = os.lstat(path)
    except OSError:
        return False

    if not stat.S_ISREG(info.st_mode):
        return False

    try:
        with open(path, "rb") as file_handle:
            return file_handle.read(4) in MACH_O_MAGICS
    except OSError:
        return False


def machine_architecture():
    if os.uname().sysname == "Darwin":
        try:
            libc = ctypes.CDLL(None)
            sysctlbyname = libc.sysctlbyname
            sysctlbyname.argtypes = [
                ctypes.c_char_p,
                ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_size_t),
                ctypes.c_void_p,
                ctypes.c_size_t,
            ]
            sysctlbyname.restype = ctypes.c_int
            arm64_supported = ctypes.c_int(0)
            size = ctypes.c_size_t(
                ctypes.sizeof(arm64_supported)
            )
            if (
                sysctlbyname(
                    b"hw.optional.arm64",
                    ctypes.byref(arm64_supported),
                    ctypes.byref(size),
                    None,
                    0,
                )
                == 0
                and arm64_supported.value == 1
            ):
                return "arm64"
        except (AttributeError, OSError):
            pass

    return os.uname().machine


def _architecture_name(cpu_type, cpu_subtype):
    subtype = cpu_subtype & 0x00FFFFFF

    if cpu_type == 7:
        return "i386"
    if cpu_type == 0x01000007:
        if subtype == 3:
            return "x86_64"
        if subtype == 8:
            return "x86_64h"
        return f"x86_64_subtype_{subtype}"
    if cpu_type == 12:
        return "arm"
    if cpu_type == 0x0100000C:
        if subtype in {0, 1}:
            return "arm64"
        if subtype == 2:
            return "arm64e"
        if subtype == 12:
            return "arm64e.x1"
        return f"arm64_subtype_{subtype}"
    if cpu_type == 0x0200000C:
        return "arm64_32"
    if cpu_type == 18:
        return "ppc"
    if cpu_type == 0x01000012:
        return "ppc64"
    return f"cpu_{cpu_type}_subtype_{subtype}"


def get_mach_slices(path):
    try:
        info = os.lstat(path)
    except OSError:
        return None

    if not stat.S_ISREG(info.st_mode):
        return None

    try:
        with open(path, "rb") as file_handle:
            prefix = file_handle.read(12)
            if len(prefix) < 4:
                return None

            magic = prefix[:4]
            thin_orders = {
                b"\xfe\xed\xfa\xce": ">",
                b"\xfe\xed\xfa\xcf": ">",
                b"\xce\xfa\xed\xfe": "<",
                b"\xcf\xfa\xed\xfe": "<",
            }
            fat_formats = {
                b"\xca\xfe\xba\xbe": (">", False),
                b"\xbe\xba\xfe\xca": ("<", False),
                b"\xca\xfe\xba\xbf": (">", True),
                b"\xbf\xba\xfe\xca": ("<", True),
            }

            if magic in thin_orders:
                if len(prefix) < 12:
                    return None
                order = thin_orders[magic]
                cpu_type, cpu_subtype = struct.unpack(
                    f"{order}II",
                    prefix[4:12],
                )
                return [
                    (
                        _architecture_name(
                            cpu_type,
                            cpu_subtype,
                        ),
                        info.st_size,
                    )
                ]

            fat = fat_formats.get(magic)
            if fat is None or len(prefix) < 8:
                return None

            order, is_64_bit = fat
            (count,) = struct.unpack(
                f"{order}I",
                prefix[4:8],
            )
            if count <= 0 or count > 64:
                return None

            entry_size = 32 if is_64_bit else 20
            file_handle.seek(8)
            entries = file_handle.read(count * entry_size)
            if len(entries) != count * entry_size:
                return None

            slices = []
            for index in range(count):
                entry = entries[
                    index * entry_size:
                    (index + 1) * entry_size
                ]
                cpu_type, cpu_subtype = struct.unpack(
                    f"{order}II",
                    entry[:8],
                )
                if is_64_bit:
                    (size,) = struct.unpack(
                        f"{order}Q",
                        entry[16:24],
                    )
                else:
                    (size,) = struct.unpack(
                        f"{order}I",
                        entry[12:16],
                    )
                slices.append(
                    (
                        _architecture_name(
                            cpu_type,
                            cpu_subtype,
                        ),
                        size,
                    )
                )
            return slices or None
    except (OSError, struct.error):
        return None


def get_architectures(path):
    slices = get_mach_slices(path)
    if not slices:
        return None
    return [architecture for architecture, _ in slices]


def preferred_architecture(architectures, target_arch):
    if not architectures or len(architectures) <= 1:
        return None

    if target_arch in architectures:
        return target_arch

    if target_arch == "arm64" and "arm64e" in architectures:
        return "arm64e"

    if target_arch == "arm64" and "arm64e.x1" in architectures:
        return "arm64e.x1"

    if target_arch == "arm64e" and "arm64" in architectures:
        return "arm64"

    if target_arch == "arm64e" and "arm64e.x1" in architectures:
        return "arm64e.x1"

    if target_arch == "x86_64" and "x86_64h" in architectures:
        return "x86_64h"

    if target_arch in {"arm64", "arm64e"} and "x86_64" in architectures:
        return "x86_64"

    if (
        target_arch in {"arm64", "arm64e"}
        and "x86_64h" in architectures
    ):
        return "x86_64h"

    return None


def is_universal(path, target_arch):
    return preferred_architecture(get_architectures(path), target_arch)


def has_valid_code_signature(path, deep=False):
    arguments = [
        CODESIGN,
        "--verify",
        "--strict",
        "--all-architectures",
        "--verbose=0",
    ]
    if deep:
        arguments.append("--deep")
    arguments.append(path)
    try:
        result = run_process(
            arguments,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return False
    return result.returncode == 0


def copy_metadata(source, destination):
    source_stat = os.stat(source, follow_symlinks=False)
    shutil.copystat(source, destination, follow_symlinks=False)

    # Preserve ownership when the caller has permission (for example root).
    try:
        os.chown(destination, source_stat.st_uid, source_stat.st_gid)
    except (AttributeError, PermissionError, OSError):
        pass

    # copystat handles extended attributes on supported macOS Python builds.
    # Repeat xattrs best-effort for Python distributions where it does not.
    if hasattr(os, "listxattr") and hasattr(os, "setxattr"):
        try:
            names = os.listxattr(source, follow_symlinks=False)
        except (OSError, TypeError):
            names = []
        for name in names:
            try:
                value = os.getxattr(
                    source,
                    name,
                    follow_symlinks=False,
                )
                os.setxattr(
                    destination,
                    name,
                    value,
                    follow_symlinks=False,
                )
            except (OSError, TypeError):
                pass


COMPRESSION_CHUNK_SIZE = 64 * 1024
COMPRESSION_LZFSE = 0x801
DECMPFS_LZFSE_RESOURCE_FORK = 12
UF_COMPRESSED = 0x20
XATTR_SHOWCOMPRESSION = 0x20
XATTR_CREATE = 0x2
DECMPFS_XATTR = b"com.apple.decmpfs"
RESOURCE_FORK_XATTR = b"com.apple.ResourceFork"


def _compression_libraries():
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.fsetxattr.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
    ]
    libc.fremovexattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    libc.fgetxattr.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
    ]
    libc.fgetxattr.restype = ctypes.c_ssize_t
    libc.fchflags.argtypes = [ctypes.c_int, ctypes.c_uint]
    compression = ctypes.CDLL("/usr/lib/libcompression.dylib")
    compression.compression_encode_scratch_buffer_size.argtypes = [ctypes.c_int]
    compression.compression_encode_scratch_buffer_size.restype = ctypes.c_size_t
    compression.compression_encode_buffer.argtypes = [
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int,
    ]
    compression.compression_encode_buffer.restype = ctypes.c_size_t
    return libc, compression


def _lzfse_resource_fork(data, compression):
    chunk_count = (len(data) + COMPRESSION_CHUNK_SIZE - 1) // COMPRESSION_CHUNK_SIZE
    scratch = ctypes.create_string_buffer(
        compression.compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
    )
    # LZFSE stores incompressible input raw with a small header.
    encoded = ctypes.create_string_buffer(COMPRESSION_CHUNK_SIZE + 1024)
    offsets = []
    chunks = []
    position = (chunk_count + 1) * 4
    for index in range(chunk_count):
        chunk = data[index * COMPRESSION_CHUNK_SIZE:(index + 1) * COMPRESSION_CHUNK_SIZE]
        length = compression.compression_encode_buffer(
            encoded, len(encoded), chunk, len(chunk), scratch, COMPRESSION_LZFSE
        )
        if length == 0:
            return None
        offsets.append(position)
        chunks.append(encoded.raw[:length])
        position += length
    offsets.append(position)
    return struct.pack(f"<{len(offsets)}I", *offsets) + b"".join(chunks)


def _read_back(path):
    with open(path, "rb") as file:
        return file.read()


def compress_file(path):
    """Store a file with macOS transparent compression (LZFSE).

    The file reads back byte-for-byte unchanged, so code signatures are
    unaffected. Returns "compressed", "unchanged" (unsupported, nothing to
    gain, or a clean failure) or "damaged" (the original could not be
    restored). Call this only after every other metadata change: copying
    flags from an uncompressed file onto a compressed one empties it.
    """
    try:
        info = os.lstat(path)
    except OSError:
        return "unchanged"
    # Opening a compressed file for writing decompresses it.
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_flags & UF_COMPRESSED
        # Other links would change too.
        or info.st_nlink != 1
        or info.st_size == 0
        or info.st_size >= 0x7FFFFFFF
    ):
        return "unchanged"

    try:
        libc, compression = _compression_libraries()
    except OSError:
        return "unchanged"

    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        # Check the file that was actually opened, not the earlier path.
        opened = os.fstat(fd)
        if (
            (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_flags & UF_COMPRESSED
            or opened.st_nlink != 1
            or opened.st_size != info.st_size
        ):
            return "unchanged"
        info = opened
        # Compression stores its data in these attributes, so an existing
        # resource fork would be overwritten. Anything but a clear "no such
        # attribute" counts as present.
        for name in (RESOURCE_FORK_XATTR, DECMPFS_XATTR):
            if libc.fgetxattr(fd, name, None, 0, 0, XATTR_SHOWCOMPRESSION) >= 0:
                return "unchanged"
            if ctypes.get_errno() != errno.ENOATTR:
                return "unchanged"
        original = os.pread(fd, info.st_size, 0)
        fork = _lzfse_resource_fork(original, compression)
        if (
            len(original) != info.st_size
            or fork is None
            or len(fork) + 4096 > info.st_size
        ):
            return "unchanged"

        header = b"fpmc" + struct.pack("<IQ", DECMPFS_LZFSE_RESOURCE_FORK, info.st_size)

        def remove_attributes():
            libc.fremovexattr(fd, DECMPFS_XATTR, XATTR_SHOWCOMPRESSION)
            libc.fremovexattr(fd, RESOURCE_FORK_XATTR, XATTR_SHOWCOMPRESSION)

        def restore_times():
            os.utime(fd, ns=(info.st_atime_ns, info.st_mtime_ns))

        def restore():
            if libc.fchflags(fd, info.st_flags & ~UF_COMPRESSED) != 0:
                return "damaged"
            remove_attributes()
            try:
                os.ftruncate(fd, 0)
                os.pwrite(fd, original, 0)
                restore_times()
            except OSError:
                return "damaged"
            return "unchanged" if _read_back(path) == original else "damaged"

        # XATTR_CREATE never replaces an attribute that appeared since the
        # check; on failure only the attributes created here are removed.
        create = XATTR_SHOWCOMPRESSION | XATTR_CREATE
        if libc.fsetxattr(fd, RESOURCE_FORK_XATTR, fork, len(fork), 0, create) != 0:
            return "unchanged"
        if libc.fsetxattr(fd, DECMPFS_XATTR, header, len(header), 0, create) != 0:
            libc.fremovexattr(fd, RESOURCE_FORK_XATTR, XATTR_SHOWCOMPRESSION)
            return "unchanged"
        try:
            os.ftruncate(fd, 0)
        except OSError:
            remove_attributes()
            return "unchanged"
        if libc.fchflags(fd, info.st_flags | UF_COMPRESSED) != 0:
            return restore()
        restore_times()
        if _read_back(path) != original:
            return restore()
        return "compressed"
    finally:
        os.close(fd)


def prepare_thinned_binary(
    bin_path,
    architecture,
    transaction_directory,
    compress=True,
):
    path = Path(bin_path)
    prepared_path = Path(transaction_directory) / (
        f"prepared-{uuid.uuid4().hex}"
    )
    result = run_process(
        [
            LIPO,
            str(path),
            "-thin",
            architecture,
            "-output",
            str(prepared_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        prepared_path.unlink(missing_ok=True)
        detail = result.stderr.strip()
        raise RuntimeError(
            f"lipo failed for {path}: {detail or 'unknown error'}"
        )

    if get_architectures(str(prepared_path)) != [architecture]:
        prepared_path.unlink(missing_ok=True)
        raise RuntimeError(
            f"Architecture validation failed for prepared binary: {path}"
        )

    try:
        copy_metadata(str(path), str(prepared_path))
    except OSError as error:
        prepared_path.unlink(missing_ok=True)
        raise RuntimeError(
            f"Failed to preserve metadata for {path}: {error}"
        ) from error

    if compress and compress_file(str(prepared_path)) == "damaged":
        prepared_path.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to compress thinned binary: {path}")

    return prepared_path


class SealedResourceIndex:
    """Identifies files a bundle signature seals as plain resources.

    Nested code (frameworks, helpers, plug-ins) is sealed by cdhash and
    survives thinning. Any other file, including Mach-O files under
    Resources such as Electron ``.node`` modules, is sealed by a hash of
    its contents, so thinning it invalidates the bundle's signature.
    """

    def __init__(self, app_path):
        self.root = str(app_path)
        self._sealing_directories = {}
        self._sealed_resources = {}

    def is_sealed_resource(self, path):
        sealing_directory = self._sealing_directory(os.path.dirname(path))
        if sealing_directory is None:
            return False
        relative_path = os.path.relpath(path, sealing_directory)
        return relative_path in self._resources(sealing_directory)

    def _sealing_directory(self, directory):
        if directory in self._sealing_directories:
            return self._sealing_directories[directory]

        if directory != self.root and not directory.startswith(
            self.root + os.sep
        ):
            result = None
        elif os.path.isfile(self._code_resources_path(directory)):
            result = directory
        elif directory == self.root:
            result = None
        else:
            result = self._sealing_directory(os.path.dirname(directory))

        self._sealing_directories[directory] = result
        return result

    def _resources(self, directory):
        if directory in self._sealed_resources:
            return self._sealed_resources[directory]

        resources = set()
        try:
            with open(self._code_resources_path(directory), "rb") as handle:
                plist = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            plist = {}

        files = plist.get("files2") or plist.get("files") or {}
        for relative_path, entry in files.items():
            if isinstance(entry, dict) and (
                "cdhash" in entry or "symlink" in entry
            ):
                continue
            resources.add(relative_path)

        self._sealed_resources[directory] = resources
        return resources

    @staticmethod
    def _code_resources_path(directory):
        return os.path.join(directory, "_CodeSignature", "CodeResources")


def signature_requirements(app, will_resign):
    """Whether the app's signature must stay valid, and whether deeply.

    Returns ``(required, deep)``. Nothing is required when the caller
    re-signs the whole app afterwards.
    """
    if will_resign:
        return False, False
    deep = has_valid_code_signature(str(app), deep=True)
    return deep or has_valid_code_signature(str(app)), deep


def plan_thinning(app, target_arch, keep_signature_valid):
    """The universal binaries thinning would change, as sorted
    ``(path, architecture to keep)`` pairs. Binaries sealed as resources
    are left out when the signature must stay valid."""
    sealed_resources = (
        SealedResourceIndex(app) if keep_signature_valid else None
    )
    planned = []
    for root, directories, files in os.walk(
        str(app),
        followlinks=False,
    ):
        directories[:] = [
            directory
            for directory in directories
            if not os.path.islink(os.path.join(root, directory))
        ]
        for filename in files:
            file_path = os.path.join(root, filename)
            if not is_mach(file_path):
                continue
            if sealed_resources and sealed_resources.is_sealed_resource(
                file_path
            ):
                continue
            architecture = is_universal(file_path, target_arch)
            if architecture:
                planned.append((file_path, architecture))

    planned.sort(key=lambda item: item[0])
    return planned


def dry_run(app_path, target_arch, will_resign):
    """Report what thinning a copy of the app would change, without
    copying or changing anything. Returns the bytes it would remove."""
    app = Path(app_path).expanduser().resolve(strict=True)
    if app.suffix.lower() != ".app" or not app.is_dir():
        raise RuntimeError(f"Input is not an application bundle: {app}")
    required, _ = signature_requirements(app, will_resign)
    removable_total = 0
    Log.append(f"\n{app.name}")
    for file_path, architecture in plan_thinning(app, target_arch, required):
        slices = get_mach_slices(file_path) or []
        removable = sum(
            size for name, size in slices if name != architecture
        )
        removable_total += removable
        Log.append(
            f"  {os.path.relpath(file_path, app)}: keep {architecture}, "
            f"remove {', '.join(n for n, _ in slices if n != architecture)} "
            f"({human_readable_size(removable)})"
        )
    if removable_total:
        Log.append(
            f"  Would remove about {human_readable_size(removable_total)} "
            "before compression."
        )
    else:
        Log.append("  Nothing to remove.")
    return removable_total


def thin_app_transactionally(app_path, target_arch, will_resign=False, compress=True):
    """Thin every universal binary in the app.

    Unless the caller re-signs the whole app afterwards (``will_resign``),
    binaries sealed as resources are skipped in signed apps and the result
    is rolled back if the existing signature no longer verifies. Thinned
    binaries are stored compressed unless ``compress`` is false.
    """
    app = Path(app_path).expanduser().resolve(strict=True)
    transaction_directory = Path(
        tempfile.mkdtemp(
            prefix=".archify-transaction-",
            dir=str(app.parent),
        )
    )
    transaction_directory.chmod(0o700)

    (
        require_signature_validation,
        require_deep_signature_validation,
    ) = signature_requirements(app, will_resign)
    # Snapshot candidates before creating staging files so we never discover
    # Archify's own temporary output during the same traversal.
    planned = plan_thinning(app, target_arch, require_signature_validation)
    prepared = []
    try:
        for file_path, architecture in planned:
            prepared_path = prepare_thinned_binary(
                file_path,
                architecture,
                transaction_directory,
                compress=compress,
            )
            prepared.append((file_path, prepared_path))
    except Exception:
        shutil.rmtree(
            transaction_directory,
            ignore_errors=True,
        )
        raise

    committed = []
    try:
        for original, prepared_path in prepared:
            backup_path = transaction_directory / (
                f"backup-{uuid.uuid4().hex}"
            )
            os.replace(original, backup_path)
            # Record the backup first: if installing the replacement fails,
            # rollback restores it, and keeps it if that fails too.
            committed.append((original, backup_path))
            os.replace(prepared_path, original)
    except Exception as error:
        rollback_errors = []
        for original, backup_path in reversed(committed):
            try:
                Path(original).unlink(missing_ok=True)
                os.replace(backup_path, original)
            except OSError as rollback_error:
                rollback_errors.append(str(rollback_error))

        rollback_detail = "; ".join(rollback_errors)
        if not rollback_errors:
            shutil.rmtree(
                transaction_directory,
                ignore_errors=True,
            )
        suffix = (
            f" Rollback also reported: {rollback_detail}"
            if rollback_detail
            else ""
        )
        recovery = (
            " Recovery data remains at "
            f"{transaction_directory}."
            if rollback_detail
            else ""
        )
        raise RuntimeError(
            "Failed to commit thinned binaries."
            f"{recovery}{suffix}"
        ) from error

    if require_signature_validation and not has_valid_code_signature(
        str(app),
        deep=require_deep_signature_validation,
    ):
        rollback_errors = []
        for original, backup_path in reversed(committed):
            try:
                Path(original).unlink(missing_ok=True)
                os.replace(backup_path, original)
            except OSError as rollback_error:
                rollback_errors.append(str(rollback_error))
        rollback_detail = "; ".join(rollback_errors)
        if not rollback_errors:
            shutil.rmtree(
                transaction_directory,
                ignore_errors=True,
            )
        suffix = (
            f" Rollback also reported: {rollback_detail}"
            if rollback_detail
            else ""
        )
        recovery = (
            " Recovery data remains at "
            f"{transaction_directory}."
            if rollback_detail
            else ""
        )
        raise RuntimeError(
            "Thinning would invalidate the application's existing "
            f"code signature.{recovery}{suffix}"
        )

    for _, backup_path in committed:
        try:
            Path(backup_path).unlink(missing_ok=True)
        except OSError as error:
            Log.append(
                f"Warning: failed to remove backup {backup_path}: {error}"
            )

    shutil.rmtree(
        transaction_directory,
        ignore_errors=True,
    )
    return [original for original, _ in prepared]


RENAME_EXCL = 0x4
ACL_TYPE_EXTENDED = 0x100
ACL_FIRST_ENTRY = 0
ACL_NEXT_ENTRY = -1
ACL_EXTENDED_ALLOW = 1
# Add file, delete, add subdirectory, delete child, write security, chown.
ACL_CHANGE_PERMISSIONS = (
    (1 << 2), (1 << 4), (1 << 5), (1 << 6), (1 << 12), (1 << 13)
)


def _acl_allows_others_to_change(path):
    """Whether an ACL lets anyone add, remove or rename entries, or change
    permissions or owner. Deny entries, such as the one on "/", are fine."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
    libc.acl_get_link_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)
    ]
    libc.acl_get_tag_type.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)
    ]
    libc.acl_get_permset.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)
    ]
    libc.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libc.acl_free.argtypes = [ctypes.c_void_p]

    acl = libc.acl_get_link_np(os.fsencode(path), ACL_TYPE_EXTENDED)
    if not acl:
        # No ACL, or one that cannot be read.
        return ctypes.get_errno() != errno.ENOENT
    try:
        entry = ctypes.c_void_p()
        which = ACL_FIRST_ENTRY
        while libc.acl_get_entry(acl, which, ctypes.byref(entry)) == 0:
            which = ACL_NEXT_ENTRY
            tag = ctypes.c_int()
            if libc.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                return True
            if tag.value != ACL_EXTENDED_ALLOW:
                continue
            permissions = ctypes.c_void_p()
            if libc.acl_get_permset(entry, ctypes.byref(permissions)) != 0:
                return True
            if any(
                libc.acl_get_perm_np(permissions, permission) == 1
                for permission in ACL_CHANGE_PERMISSIONS
            ):
                return True
        return False
    finally:
        libc.acl_free(acl)


# wheel and admin: their members can already act as root, so a folder they
# can change, such as /Applications, is no less safe.
PRIVILEGED_GROUPS = (0, 80)


def is_trusted_directory(path):
    """Whether no one but this user and administrators can add, remove or
    rename entries in ``path`` or any folder above it. Sticky folders such as
    /tmp qualify, since others cannot rename what they don't own."""
    path = Path(path)
    if not path.is_absolute():
        return False
    user = os.geteuid()
    current = Path("/")
    for part in path.parts:
        current = current / part
        try:
            # lstat: a link anywhere in the path is refused, not followed.
            info = os.lstat(current)
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, user):
            return False
        if not info.st_mode & stat.S_ISVTX and (
            info.st_mode & 0o002
            or (info.st_mode & 0o020 and info.st_gid not in PRIVILEGED_GROUPS)
        ):
            return False
        if _acl_allows_others_to_change(str(current)):
            return False
    return True


def rename_exclusive(source, destination):
    """Rename that fails with FileExistsError if ``destination`` exists."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renamex_np.restype = ctypes.c_int
    if libc.renamex_np(
        os.fsencode(source), os.fsencode(destination), RENAME_EXCL
    ) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def duplicate_app(app_dir, output_dir):
    source = Path(app_dir).expanduser().resolve(strict=True)
    destination_root = (
        Path(output_dir).expanduser().resolve(strict=True)
    )

    if source.suffix.lower() != ".app" or not source.is_dir():
        raise RuntimeError(
            f"Input is not an application bundle: {source}"
        )
    if not destination_root.is_dir():
        raise RuntimeError(
            f"Output directory does not exist: {destination_root}"
        )

    destination = destination_root / source.name
    if destination.resolve(strict=False) == source:
        raise RuntimeError(
            "Input and output application paths are identical."
        )
    if destination.exists():
        raise RuntimeError(
            "Destination already exists; refusing to merge into it: "
            f"{destination}"
        )

    # Copy into a private folder, then move the copy into place only if
    # nothing exists there yet. A failed copy never touches, or cleans up,
    # anything Archify did not create. That folder could be swapped out if
    # other users can change the destination.
    # Check one resolved folder, then use exactly that path from here on.
    destination_root = Path(os.path.realpath(destination_root))
    destination = destination_root / source.name
    if not is_trusted_directory(destination_root):
        raise RuntimeError(
            "Choose an output folder that other users can't change: "
            f"{destination_root}"
        )
    staging = Path(
        tempfile.mkdtemp(prefix=".archify-copy-", dir=str(destination_root))
    )
    try:
        staged = staging / source.name
        environment = os.environ.copy()
        environment["DITTOABORT"] = "1"
        result = run_process(
            [
                DITTO,
                "--rsrc",
                "--extattr",
                "--acl",
                str(source),
                str(staged),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        if result.returncode != 0:
            detail = result.stderr.strip()
            raise RuntimeError(
                f"Failed to copy app: {detail or 'ditto failed'}"
            )
        if not staged.is_dir() or staged.is_symlink():
            raise RuntimeError(
                "Copy completed without a valid destination app bundle."
            )
        try:
            rename_exclusive(staged, destination)
        except FileExistsError:
            raise RuntimeError(
                "Destination already exists; refusing to merge into it: "
                f"{destination}"
            ) from None
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    return str(destination)


def find_compatible_ldid(explicit_path=None):
    candidates = []
    if explicit_path:
        candidates.append(explicit_path)

    path_candidate = shutil.which("ldid")
    if path_candidate:
        candidates.append(path_candidate)

    candidates.extend(
        [
            "/opt/homebrew/bin/ldid",
            "/usr/local/bin/ldid",
        ]
    )

    host_arch = machine_architecture()
    seen = set()
    for candidate in candidates:
        candidate = os.path.realpath(os.path.expanduser(candidate))
        if candidate in seen:
            continue
        seen.add(candidate)
        if (
            not os.path.isfile(candidate)
            or not os.access(candidate, os.X_OK)
        ):
            continue
        architectures = get_architectures(candidate)
        if architectures and host_arch in architectures:
            return candidate

    return None


def extract_entitlements(app_path):
    """Return a temporary entitlements file, "" if the app has none, or
    None on failure."""
    result = run_process(
        [
            CODESIGN,
            "-d",
            "--entitlements",
            "-",
            "--xml",
            app_path,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        Log.append(
            "Failed to extract entitlements: "
            + result.stderr.decode(errors="replace").strip()
        )
        return None
    if not result.stdout.strip():
        Log.append(
            f"No entitlements found in {app_path}; "
            "signing without entitlements"
        )
        return ""

    with tempfile.NamedTemporaryFile(
        suffix=".xml",
        delete=False,
    ) as temp_file:
        temp_file.write(result.stdout)
        return temp_file.name


def sign_bin_with_ldid(bin_path, no_entitlements):
    entitlements_path = None
    try:
        if not no_entitlements:
            result = run_process(
                [LDID, "-e", bin_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 0:
                Log.append(
                    "Failed to extract ldid entitlements for "
                    f"{bin_path}"
                )
                return False
            if result.stdout.strip():
                with tempfile.NamedTemporaryFile(
                    suffix=".xml",
                    delete=False,
                ) as temp_file:
                    temp_file.write(result.stdout)
                    entitlements_path = temp_file.name

        arguments = [LDID, "-S", bin_path]
        if entitlements_path:
            arguments = [
                LDID,
                f"-S{entitlements_path}",
                bin_path,
            ]

        result = run_process(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            Log.append(
                f"Failed to sign {bin_path} with ldid: "
                + result.stderr.decode(errors="replace").strip()
            )
            return False
        return True
    finally:
        if entitlements_path:
            Path(entitlements_path).unlink(missing_ok=True)


def sign_app_with_codesign(app_path, no_entitlements):
    entitlements_path = None
    try:
        if not no_entitlements:
            entitlements_path = extract_entitlements(app_path)
            if entitlements_path is None:
                return False

        # Sign nested code without entitlements first, then re-sign only the
        # outer app with the main executable's entitlements. Combining
        # --deep with --entitlements would copy them onto every nested
        # helper, framework, and plug-in.
        commands = [
            [CODESIGN, "--force", "--deep", "--sign", "-", app_path]
        ]
        if entitlements_path:
            commands.append(
                [
                    CODESIGN,
                    "--force",
                    "--sign",
                    "-",
                    "--entitlements",
                    entitlements_path,
                    app_path,
                ]
            )

        for command in commands:
            result = run_process(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 0:
                Log.append(
                    f"Failed to ad-hoc sign {app_path} with codesign: "
                    + result.stderr.decode(errors="replace").strip()
                )
                return False

        Log.append(
            f"Successfully ad-hoc signed {app_path} with codesign"
        )
        return True
    finally:
        if entitlements_path:
            Path(entitlements_path).unlink(missing_ok=True)


def bundle_executable_path(app_path):
    app = Path(app_path).expanduser().resolve(strict=True)
    candidates = [
        (
            app / "Contents" / "Info.plist",
            app / "Contents" / "MacOS",
        ),
        (app / "Info.plist", app),
    ]

    for info_path, executable_root in candidates:
        if not info_path.is_file():
            continue
        try:
            with info_path.open("rb") as info_file:
                info = plistlib.load(info_file)
        except (OSError, plistlib.InvalidFileException):
            continue

        executable_name = info.get("CFBundleExecutable")
        if (
            not isinstance(executable_name, str)
            or not executable_name
        ):
            continue

        executable = (
            executable_root / executable_name
        ).resolve(strict=False)
        try:
            executable.relative_to(app)
        except ValueError:
            continue
        if executable.is_file():
            return str(executable)

    return None


def running_pids_for_executable(executable_path):
    expected = os.path.realpath(executable_path)
    result = run_process(
        [PS, "-axo", "pid=,comm="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        return set()

    pids = set()
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) != 2:
            continue
        pid_text, command = parts
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if os.path.realpath(command) == expected:
            pids.add(pid)
    return pids


def process_matches_executable(pid, executable_path):
    result = run_process(
        [PS, "-p", str(pid), "-o", "comm="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        return False
    return (
        os.path.realpath(result.stdout.strip())
        == os.path.realpath(executable_path)
    )


def open_app(app_path):
    executable = bundle_executable_path(app_path)
    if not executable:
        Log.append(
            "Could not resolve the app's declared executable."
        )
        return None

    before = running_pids_for_executable(executable)
    result = run_process(
        [OPEN, "-n", app_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        Log.append(
            "Failed to open app: "
            + (result.stderr.strip() or "open failed")
        )
        return None

    time.sleep(10)
    launched_pids = (
        running_pids_for_executable(executable) - before
    )
    # If the app exited during the warm-up period, there is nothing left to
    # terminate and, importantly, no PID is guessed.
    return executable, launched_pids


def terminate_process(pid, expected_executable, timeout=5.0):
    if not process_matches_executable(
        pid,
        expected_executable,
    ):
        return True

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    except OSError as error:
        Log.append(
            f"Failed to terminate process {pid}: {error}"
        )
        return False

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_matches_executable(
            pid,
            expected_executable,
        ):
            return True
        time.sleep(0.1)

    # Revalidate immediately before SIGKILL so PID reuse cannot target an
    # unrelated executable.
    if not process_matches_executable(
        pid,
        expected_executable,
    ):
        return True

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return True
    except OSError as error:
        Log.append(
            f"Failed to force terminate process {pid}: {error}"
        )
        return False

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_matches_executable(
            pid,
            expected_executable,
        ):
            return True
        time.sleep(0.1)
    return not process_matches_executable(
        pid,
        expected_executable,
    )


def calculate_app_size(app_path):
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(
        app_path,
        followlinks=False,
    ):
        dirnames[:] = [
            name
            for name in dirnames
            if not os.path.islink(
                os.path.join(dirpath, name)
            )
        ]
        for filename in filenames:
            file_path = os.path.join(dirpath, filename)
            if os.path.islink(file_path):
                continue
            try:
                # Space on disk, so compression is reflected.
                total_size += os.lstat(file_path).st_blocks * 512
            except OSError:
                continue
    return total_size


def human_readable_size(size, decimal_places=2):
    size = max(0, size)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size < 1024:
            return f"{size:.{decimal_places}f} {unit}"
        size /= 1024
    return f"{size:.{decimal_places}f} PB"


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-app",
        "--app_dir",
        nargs="+",
        type=str,
        required=True,
        help="The app to archify",
    )
    parser.add_argument(
        "-o",
        "--output_dir",
        type=str,
        default=os.getcwd(),
        help=(
            "Where the copy of the app is stored; "
            "defaults to working directory"
        ),
    )
    parser.add_argument(
        "-arch",
        "--arch",
        type=str,
        default=machine_architecture(),
        help=(
            "The architecture to archify to; "
            "default: this Mac's physical architecture"
        ),
    )
    parser.add_argument(
        "-ld",
        "--ldid",
        type=str,
        help=(
            "The path to a native ldid executable "
            "for resigning binaries"
        ),
    )
    parser.add_argument(
        "-Ns",
        "--no_sign",
        help="Do not sign the binaries with ldid",
        action="store_true",
    )
    parser.add_argument(
        "-Ne",
        "--no_entitlements",
        help=(
            "Do not sign the binaries with original "
            "entitlements with ldid"
        ),
        action="store_true",
    )
    parser.add_argument(
        "-cs",
        "--codesign",
        help="Ad-hoc sign the entire app with codesign",
        action="store_true",
    )
    parser.add_argument(
        "-l",
        "--no_launch",
        default=False,
        help=(
            "Do not launch the copied app before processing"
        ),
        action="store_true",
    )
    parser.add_argument(
        "-n",
        "--dry_run",
        default=False,
        help=(
            "Only report which binaries would be thinned and how much "
            "space that would free; nothing is copied or changed"
        ),
        action="store_true",
    )
    parser.add_argument(
        "-Nc",
        "--no_compress",
        default=False,
        help=(
            "Do not store thinned binaries with macOS transparent "
            "compression"
        ),
        action="store_true",
    )
    return parser.parse_args()


def main():
    global LDID
    Log.log_buffer = []
    args = parse_arguments()

    # archify.py only changes copies in a folder you choose, so it never
    # needs root, and as root it could be redirected by other programs.
    if os.geteuid() == 0:
        Log.append(
            "Run archify.py as your own user, not as root or with sudo. "
            "It works on copies, so it doesn't need administrator rights."
        )
        return 1
    app_dirs = sorted(set(args.app_dir))

    if args.dry_run:
        exit_status = 0
        total = 0
        for app_dir in app_dirs:
            try:
                total += dry_run(app_dir, args.arch, args.codesign)
            except OSError as error:
                Log.append(f"App is not accessible: {app_dir}: {error}")
                exit_status = 1
            except RuntimeError as error:
                Log.append(str(error))
                exit_status = 1
        if len(app_dirs) > 1:
            Log.append(
                f"\nTotal: about {human_readable_size(total)} "
                "before compression."
            )
        Log.append("Dry run: nothing was copied or changed.")
        return exit_status

    try:
        output_dir = str(
            Path(args.output_dir)
            .expanduser()
            .resolve(strict=True)
        )
    except OSError as error:
        Log.append(
            f"Output directory is not accessible: {error}"
        )
        return 1

    if not os.path.isdir(output_dir):
        Log.append(
            f"Output path is not a directory: {output_dir}"
        )
        return 1

    # Everything, including the log, is written beneath this folder, so no
    # other user may be able to swap it, or a folder above it, out.
    output_dir = os.path.realpath(output_dir)
    if not is_trusted_directory(output_dir):
        Log.append(
            "Choose an output folder that other users can't change: "
            f"{output_dir}"
        )
        return 1

    LDID = ""
    if not args.no_sign:
        LDID = find_compatible_ldid(args.ldid)
        if args.ldid and not LDID:
            Log.append(
                "Specified ldid is missing or incompatible "
                "with this Mac."
            )
        if not LDID:
            Log.append(
                "No compatible ldid found; "
                "continuing without LDID signing."
            )

    exit_status = 0

    for app_dir in app_dirs:
        try:
            source_app = str(
                Path(app_dir)
                .expanduser()
                .resolve(strict=True)
            )
        except OSError as error:
            Log.append(
                f"App is not accessible: {app_dir}: {error}"
            )
            exit_status = 1
            continue

        Log.append(
            f"\nCreating a copy at {output_dir} "
            f"({os.path.basename(source_app)})"
        )
        try:
            output_app_dir = duplicate_app(
                source_app,
                output_dir,
            )
        except (OSError, RuntimeError) as error:
            Log.append(
                f"Failed to duplicate app: {error}"
            )
            exit_status = 1
            continue

        initial_size = calculate_app_size(source_app)
        Log.append(
            "Initial App Size: "
            + human_readable_size(initial_size)
        )

        if not args.no_launch:
            Log.append("Opening the app to initialize")
            launch_result = open_app(output_app_dir)
            if launch_result:
                executable, pids = launch_result
                for pid in sorted(pids):
                    Log.append(
                        f"Terminating launched app process {pid}"
                    )
                    if not terminate_process(
                        pid,
                        executable,
                    ):
                        Log.append(
                            "Failed to terminate launched "
                            f"app process {pid}"
                        )
                        exit_status = 1

        Log.append("\nExtracting the target binaries")
        try:
            changed_paths = thin_app_transactionally(
                output_app_dir,
                args.arch,
                will_resign=args.codesign,
                compress=not args.no_compress,
            )
        except (OSError, RuntimeError) as error:
            Log.append(
                "Failed to thin app transactionally: "
                f"{error}"
            )
            exit_status = 1
            continue

        signing_ok = True
        if (
            LDID
            and not args.no_sign
            and changed_paths
            and not args.codesign
            and has_valid_code_signature(output_app_dir)
        ):
            # Thinning kept the original signature valid; re-signing with
            # ldid would only replace it with an ad-hoc one.
            Log.append(
                "Existing code signature is still valid; "
                "skipping ldid re-signing"
            )
        elif LDID and not args.no_sign:
            for file_path in changed_paths:
                Log.append(f"Signing {file_path}")
                if not sign_bin_with_ldid(
                    file_path,
                    args.no_entitlements,
                ):
                    signing_ok = False

        if args.codesign:
            Log.append(
                "Ad-hoc signing the entire app with codesign"
            )
            if not sign_app_with_codesign(
                output_app_dir,
                args.no_entitlements,
            ):
                signing_ok = False

        if not signing_ok:
            exit_status = 1

        final_size = calculate_app_size(output_app_dir)
        saved_size = max(0, initial_size - final_size)
        saved_percent = (
            (saved_size / initial_size) * 100
            if initial_size
            else 0
        )
        Log.append(
            "Final App Size: "
            + human_readable_size(final_size)
        )
        Log.append(
            f"\nSaved: {human_readable_size(saved_size)}, "
            f"{saved_percent:.2f}%"
        )

        Log.save_log_to_file(
            os.path.join(output_dir, "process_log.txt")
        )

    return exit_status


if __name__ == "__main__":
    raise SystemExit(main())
