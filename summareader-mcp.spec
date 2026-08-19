# What PyInstaller has to be told, and why each line is here.
#
#   uv run --with pyinstaller pyinstaller --clean --noconfirm summareader-mcp.spec
#
# scripts/freeze.sh is that line with the checks around it. The result is one
# executable in dist/ that needs no Python on the machine it runs on — which is
# the point: a desktop app cannot ask somebody to install an interpreter first.

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# The schema is read at runtime through importlib.resources, so it has to
# arrive as a file inside the package rather than be compiled into the archive
# as a module. This is the one datafile the mirror cannot start without.
datas = [("summareader_mcp/store/schema.sql", "summareader_mcp/store")]

# Textual keeps its stylesheets and its widget CSS beside its code, and finds
# them the same way — nothing imports them, so nothing drags them in.
datas += collect_data_files("textual")

# Imported by name at runtime and therefore invisible to the analysis:
# textual's widgets are resolved through its own registry, and mcp's HTTP
# transport pulls uvicorn's protocol implementations by string.
hiddenimports = (
    collect_submodules("textual.widgets")
    + collect_submodules("uvicorn")
    + ["summareader_mcp.tui", "summareader_mcp.gui"]
)

analysis = Analysis(
    ["summareader_mcp/__main__.py"],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    # tkinter is not excluded any more: the `gui` subcommand is built on it,
    # and a frozen bundle without it is a window that only exists in a
    # checkout. It is in the standard library, so this costs the toolkit's own
    # shared libraries and nothing in the dependency list.
    excludes=["pytest", "IPython"],
    noarchive=False,
)
pyz = PYZ(analysis.pure)

EXE(
    pyz,
    analysis.scripts,
    analysis.binaries,
    analysis.datas,
    [],
    name="summareader-mcp",
    debug=False,
    strip=False,
    upx=False,
    console=True,
)
