"""`python -m summareader_mcp`, and the entry point a frozen build starts at.

A console script is a generated shim that only exists once the package is
installed; a frozen executable has no such shim and no installed package to
generate one from, so both want a module that simply runs.
"""

# Absolute, not relative: PyInstaller runs this file as the top-level script,
# where there is no parent package for a relative import to be relative to.
from summareader_mcp.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
