"""Quick standalone test of qCumber subprocess behaviour."""
import subprocess, tempfile, os, json, shutil, glob

HOME = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
Q_BIN = f"{HOME}/.kx/bin/q"

import platform
# On arm64 macOS the universal q binary must run as x86_64 (Rosetta 2) so that
# the x86_64-only native libs in ax-libraries/ws/lib/osx_x64/ can be loaded.
FORCE_X86 = (platform.machine() == "arm64" and platform.system() == "Darwin")
if FORCE_X86:
    # arch -x86_64 forces Rosetta 2 execution
    CMD_PREFIX = ["arch", "-x86_64"]
else:
    CMD_PREFIX = []

# ---------------------------------------------------------------------------
# Resolve qcumber.q_ — mirrors the priority order in _find_qcumber():
#   1. vendor/ax-libraries  (project-local, --project flag)
#   2. ~/.kx/ax-libraries   (standard KX tooling home, default install target)
#   3. AXLIBRARIES_HOME env var
#   4. ~/developer-*/analyst
#   5. ~/developer-*/ax-libraries
# ---------------------------------------------------------------------------
def _find_qcumber_and_ax_home():
    """Return (qcumber_path, ax_home) using the same priority as the MCP server."""
    # 1. Project-local vendor (installed via scripts/install_ax_libraries.sh --project)
    vendor_ax   = os.path.join(PROJECT_ROOT, "vendor", "ax-libraries")
    vendor_qc   = os.path.join(vendor_ax, "ws", "qcumber.q_")
    if os.path.isfile(vendor_qc):
        return vendor_qc, vendor_ax

    # 2. Standard KX tooling home: ~/.kx/ax-libraries (default install target)
    kx_ax = os.path.join(HOME, ".kx", "ax-libraries")
    kx_qc = os.path.join(kx_ax, "ws", "qcumber.q_")
    if os.path.isfile(kx_qc):
        return kx_qc, kx_ax

    # 3. AXLIBRARIES_HOME env var
    ax_env = os.environ.get("AXLIBRARIES_HOME", "")
    if ax_env and os.path.isfile(os.path.join(ax_env, "ws", "qcumber.q_")):
        return os.path.join(ax_env, "ws", "qcumber.q_"), ax_env

    # 4. ~/developer-*/analyst   (analyst ships its own qcumber + sub-deps)
    for pattern in [
        f"{HOME}/developer-*-osx/analyst/ws/qcumber.q_",
        f"{HOME}/developer-*-linux/analyst/ws/qcumber.q_",
        f"{HOME}/developer-*/analyst/ws/qcumber.q_",
    ]:
        matches = sorted(glob.glob(pattern), reverse=True)
        if matches:
            qc = matches[0]
            # ax_home is the sibling ax-libraries of analyst/
            root = os.path.dirname(os.path.dirname(os.path.dirname(qc)))
            ax = os.path.join(root, "ax-libraries")
            return qc, ax if os.path.isdir(ax) else os.path.dirname(os.path.dirname(qc))

    # 5. ~/developer-*/ax-libraries
    for pattern in [
        f"{HOME}/developer-*-osx/ax-libraries/ws/qcumber.q_",
        f"{HOME}/developer-*-linux/ax-libraries/ws/qcumber.q_",
        f"{HOME}/developer-*/ax-libraries/ws/qcumber.q_",
    ]:
        matches = sorted(glob.glob(pattern), reverse=True)
        if matches:
            qc = matches[0]
            ax = os.path.dirname(os.path.dirname(qc))
            return qc, ax

    return "", ""

QCUMBER, AX_HOME = _find_qcumber_and_ax_home()

tmpdir = tempfile.mkdtemp(prefix="qcumber_test_")
quke   = os.path.join(tmpdir, "test.quke")
setup  = os.path.join(tmpdir, "setup.q")
out    = os.path.join(tmpdir, "results.json")

with open(setup, "w") as f:
    f.write("double:{x*2}")

with open(quke, "w") as f:
    f.write(
        "feature double function\n\n"
        "    should multiply by two\n"
        "        expect double 5 equals 10\n"
        "            10 ~ double[5]\n\n"
        "        expect intentional failure\n"
        "            99 ~ double[5]\n"
    )

ax_ws = os.path.join(AX_HOME, "ws") if AX_HOME else ""  # ax-libraries/ws/
ax_lib_arch = os.path.join(ax_ws, "lib", "osx_x64" if FORCE_X86 else "ubuntu20_x64")
ax_lib = os.path.join(ax_ws, "lib")

env = {
    **os.environ,
    "QLIC": f"{HOME}/.kx",
    "AXLIBRARIES_HOME": AX_HOME,
    # macOS: help dlopen find q_fs.so from the platform-specific osx_x64/ dir
    "DYLD_LIBRARY_PATH": f"{ax_lib_arch}:{ax_lib}:{os.environ.get('DYLD_LIBRARY_PATH', '')}",
    # Linux equivalent (no-op on macOS)
    "LD_LIBRARY_PATH": f"{ax_lib_arch}:{ax_lib}:{os.environ.get('LD_LIBRARY_PATH', '')}",
}
print(f"AXLIBRARIES_HOME = {AX_HOME}")
print(f"DYLD_LIBRARY_PATH will include = {ax_lib_arch}")
print(f"qcumber          = {QCUMBER}")
cmd = CMD_PREFIX + [Q_BIN, QCUMBER, "-src", setup, "-test", quke, "-out", out, "-quiet"]

print("Running:", " ".join(cmd))
try:
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=90,
        env=env,
        cwd=ax_ws,   # run from ax-libraries/ws/ so \l .qu.to finds .qu.to.q_
        stdin=subprocess.DEVNULL,
    )
    print("Exit code:", proc.returncode)
    print("STDOUT:", proc.stdout[:500] or "(none)")
    print("STDERR:", proc.stderr[:500] or "(none)")
    if os.path.isfile(out):
        print("JSON:", json.dumps(json.load(open(out)), indent=2))
    else:
        print("No JSON output file produced")
except subprocess.TimeoutExpired as e:
    print("TIMEOUT — qcumber did not finish in 90 s")
    print("Partial stdout:", e.stdout[:500] if e.stdout else "(none)")
    print("Partial stderr:", e.stderr[:500] if e.stderr else "(none)")
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
