"""Send an LSP `initialize` to the ols shim over stdio and expect a response.

Exercises the part of a shim most likely to break: passing stdin/stdout
through to the real binary (editors talk to ols this way).
"""
import json
import shutil
import subprocess
import sys

ols = shutil.which("ols")
if not ols:
    sys.exit("ols not on PATH")

body = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"processId": None, "rootUri": None, "capabilities": {}},
}).encode()
proc = subprocess.Popen([ols], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()
    header = proc.stdout.readline()
    if not header.startswith(b"Content-Length:"):
        sys.exit(f"unexpected reply from {ols}: {header!r}")
    print(f"ols ({ols}) answered initialize: {header.strip().decode()}")
finally:
    proc.kill()
