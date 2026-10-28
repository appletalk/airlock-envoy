# Run a command as the airlock-envoy units do under MemoryDenyWriteExecute: no memory may become
# executable once writable. prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN) (Linux 6.3+), kept
# across exec, then exec. LuaJIT compiling a trace needs exactly that, so a Lua filter without
# jit.off() panics Envoy here as on a host.
# Usage: python3 -I test/mdwe-exec.py <command> [args...]
# Exits 3 without running anything if the kernel lacks PR_SET_MDWE.
import ctypes, os, sys

PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN = 65, 1
if len(sys.argv) < 2:
    sys.exit("usage: mdwe-exec.py <command> [args...]")
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0) != 0:
    print("mdwe-exec: prctl(PR_SET_MDWE) failed: %s (Linux 6.3+ needed)" % os.strerror(ctypes.get_errno()), file=sys.stderr)
    sys.exit(3)
os.execvp(sys.argv[1], sys.argv[1:])
