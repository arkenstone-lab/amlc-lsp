"""Verify the default official-library install, not the legacy package build."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    prefix = Path(sys.argv[1]).resolve()
    executable_suffix = ".exe" if os.name == "nt" else ""
    server = prefix / "bin" / f"amlc-lsp{executable_suffix}"
    assert server.is_file() and os.access(server, os.X_OK), server
    dependency_switch = "--dependency-switch" in sys.argv[2:]
    if dependency_switch:
        assert os.access(prefix / "bin" / f"amlc{executable_suffix}", os.X_OK), "missing AMLC dependency"
    else:
        assert not (prefix / "bin/amlc").exists(), "unexpected bundled compiler"
    for relative in (f"bin/rehovot-check{executable_suffix}", "lib/amlc-lsp/amlc",
                     "lib/amlc-lsp/rehovot-check"):
        assert not (prefix / relative).exists(), f"unexpected bundled tool: {relative}"
    docdir = "share/doc/amlc-lsp" if "--nix" in sys.argv[2:] else "doc/amlc-lsp"
    for relative in ("LICENSE", "THIRD_PARTY_NOTICES.md", "official-amlc-adapter.md"):
        assert (prefix / docdir / relative).is_file(), relative
    subprocess.run([sys.executable, str(Path(__file__).with_name("server_test.py")),
                    str(server)], check=True)
    print("Official AMLC install: installed server works without private compiler/helper tools.")


if __name__ == "__main__":
    main()
