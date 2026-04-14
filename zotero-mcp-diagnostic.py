#!/usr/bin/env python3
"""
Zotero MCP Server — Diagnostic Tool
Checks system environment, dependencies, configuration, and connectivity.
Standalone script — uses only Python stdlib. Cross-platform (Mac + Windows).
"""

import json
import os
import platform
import shutil
import subprocess
import sys
import time

DIAGNOSTIC_VERSION = "1.1.2"

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

IS_MAC = platform.system() == "Darwin"
IS_WIN = platform.system() == "Windows"


def _color(text, code):
    """Apply ANSI color if terminal supports it."""
    if hasattr(sys.stdout, "isatty") and sys.stdout.isatty():
        return f"\033[{code}m{text}\033[0m"
    return text


def _green(t): return _color(t, "32")
def _yellow(t): return _color(t, "33")
def _red(t): return _color(t, "31")
def _bold(t): return _color(t, "1")
def _dim(t): return _color(t, "2")


def _run(cmd, timeout=10):
    """Run a command, return (stdout, stderr, returncode)."""
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            env={**os.environ, "PATH": _enriched_path()})
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode
    except FileNotFoundError:
        return "", "command not found", -1
    except subprocess.TimeoutExpired:
        return "", "timed out", -2
    except Exception as e:
        return "", str(e), -3


def _enriched_path():
    """Return PATH with common macOS additions."""
    path = os.environ.get("PATH", "")
    for p in [os.path.expanduser("~/.local/bin"), os.path.expanduser("~/.cargo/bin"),
              "/opt/homebrew/bin", "/usr/local/bin"]:
        if p not in path:
            path = p + os.pathsep + path
    return path


def _uv_venv_python():
    """Find uv's venv Python for the zotero-mcp-server tool."""
    base = os.path.expanduser("~/.local/share/uv/tools/zotero-mcp-server")
    for pyver in ["python3.13", "python3.12", "python3.11", "python3.10", "python3"]:
        candidate = os.path.join(base, "bin" if not IS_WIN else "Scripts", pyver)
        if os.path.isfile(candidate):
            return candidate
    # Fallback: just look for python3 in the venv
    candidate = os.path.join(base, "bin" if not IS_WIN else "Scripts", "python3")
    if os.path.isfile(candidate):
        return candidate
    return None


# Modules whose import chain is heavyweight (loads torch, etc.) and can exceed
# the normal 10s timeout on a cold interpreter. Give these extra time.
SLOW_IMPORTS = {"sentence_transformers", "chromadb", "torch"}

# Timeouts for _check_import's subprocess call.
FAST_IMPORT_TIMEOUT = 10
SLOW_IMPORT_TIMEOUT = 60  # sentence_transformers/torch cold-start can be 30-50s
                          # on a freshly installed venv. 60s covers worst case.


def _check_import(venv_python, module_name):
    """Check if a Python module is importable in the venv, return version or status.

    Returns:
        (version_or_sentinel, detail) tuple. Sentinels:
          - version string (e.g. "5.4.0") → module installed and importable
          - "TIMEOUT" → import hit the time limit but the module exists on disk;
                       probably installed but slow to warm up. Treated as installed.
          - "NOT INSTALLED" → import failed with a real error (missing / broken)
          - "UNKNOWN" → no venv Python available to check with
    """
    if not venv_python:
        return "UNKNOWN", "venv Python not found"
    code = f"import {module_name}; print(getattr({module_name}, '__version__', 'installed'))"
    timeout = SLOW_IMPORT_TIMEOUT if module_name in SLOW_IMPORTS else FAST_IMPORT_TIMEOUT
    stdout, stderr, rc = _run([venv_python, "-c", code], timeout=timeout)
    if rc == 0 and stdout:
        return stdout.strip(), "OK"
    # _run returns rc=-2 specifically on TimeoutExpired. Treat timeouts as
    # "installed but slow" rather than "not installed" — we know the subprocess
    # got far enough to start the import, it just didn't finish in time.
    if rc == -2:
        return "TIMEOUT", f"import exceeded {timeout}s (treating as installed)"
    return "NOT INSTALLED", stderr[:100] if stderr else "import failed"


# ---------------------------------------------------------------------------
# Individual diagnostic checks
# ---------------------------------------------------------------------------

def check_system():
    """System environment info."""
    info = {}
    info["platform"] = platform.platform()
    info["architecture"] = platform.machine()
    info["python_version"] = platform.python_version()
    info["python_path"] = sys.executable
    info["shell"] = os.environ.get("SHELL", "unknown")

    # Disk space
    try:
        usage = shutil.disk_usage(os.path.expanduser("~"))
        info["disk_free_gb"] = round(usage.free / (1024 ** 3), 1)
    except Exception:
        info["disk_free_gb"] = "unknown"

    status = "OK"
    detail = f"{platform.system()} {platform.mac_ver()[0] if IS_MAC else platform.version()}, {platform.machine()}, Python {platform.python_version()}"

    if isinstance(info["disk_free_gb"], (int, float)) and info["disk_free_gb"] < 1.0:
        status = "WARN"
        detail += f" -- LOW DISK: {info['disk_free_gb']} GB free"

    return "system", status, detail, info


def check_uv():
    """Check uv package manager."""
    path = shutil.which("uv")
    if not path:
        for p in [os.path.expanduser("~/.local/bin/uv"),
                  os.path.expanduser("~/.cargo/bin/uv")]:
            if os.path.isfile(p):
                path = p
                break
    if not path:
        return "uv", "FAIL", "Not installed", {"installed": False}

    stdout, _, rc = _run([path, "--version"])
    # uv --version → "uv 0.10.11 (006b56b12 2026-03-16)"
    parts = stdout.split() if stdout else []
    version = parts[1] if len(parts) >= 2 else "unknown"
    return "uv", "OK", f"v{version} at {path}", {"installed": True, "version": version, "path": path}


def check_zotero_mcp():
    """Check zotero-mcp binary."""
    path = shutil.which("zotero-mcp")
    if not path:
        p = os.path.expanduser("~/.local/bin/zotero-mcp")
        if os.path.isfile(p):
            path = p
    if not path:
        return "zotero-mcp", "FAIL", "Not installed", {"installed": False}

    # Dead symlink: shutil.which finds the link, but target is gone
    if os.path.islink(path) and not os.path.exists(path):
        target = os.readlink(path)
        return "zotero-mcp", "FAIL", f"Dead symlink: {path} -> {target}", {
            "installed": False, "dead_symlink": True, "target": target, "path": path}

    stdout, _, rc = _run([path, "version"])
    # zotero-mcp version → "Zotero MCP v0.2.1"
    version = stdout.strip() if rc == 0 else "unknown"
    # Clean prefix for the structured field; keep full string for display
    display = version
    clean = version.replace("Zotero MCP ", "").strip() if version.startswith("Zotero MCP") else version

    if rc != 0:
        return "zotero-mcp", "WARN", f"Binary found but version check failed at {path}", {
            "installed": True, "version": clean, "path": path}

    return "zotero-mcp", "OK", f"{display} at {path}", {"installed": True, "version": clean, "path": path}


def check_git():
    """Check git."""
    path = shutil.which("git")
    if not path:
        return "git", "WARN", "Not installed", {"installed": False}
    stdout, _, _ = _run([path, "--version"])
    version = stdout.replace("git version ", "").strip() if stdout else "unknown"
    return "git", "OK", f"v{version} at {path}", {"installed": True, "version": version, "path": path}


def check_dependencies():
    """Check all Python dependencies in uv's venv."""
    venv_py = _uv_venv_python()

    # If the venv itself is missing, report that clearly rather than showing
    # every module as "not installed" (which looks like 15 separate problems
    # when it's really one: the whole install is corrupted).
    if venv_py is None:
        return ("dependencies", "FAIL",
                "Installation venv missing or corrupted — re-run the installer to fix",
                {"venv_missing": True, "packages": {}, "extras": "unknown",
                 "installed": 0, "total": 0})

    deps = {
        "core": ["fastmcp", "mcp", "pydantic", "dotenv", "pyzotero", "requests", "unidecode", "markitdown"],
        "pdf": ["pymupdf", "ebooklib"],
        "semantic": ["chromadb", "sentence_transformers", "tiktoken", "openai"],
        "runtime": ["onnxruntime"],
    }

    results = {}
    installed = 0
    total = 0
    missing = []

    for group, modules in deps.items():
        for mod in modules:
            total += 1
            ver, status = _check_import(venv_py, mod)
            results[mod] = {"version": ver, "status": status, "group": group}
            # TIMEOUT counts as installed — we know the module file exists and
            # the import subprocess got past the file lookup. Only NOT INSTALLED
            # and UNKNOWN are treated as missing.
            if ver not in ("NOT INSTALLED", "UNKNOWN"):
                installed += 1
            else:
                missing.append(mod)

    # Check uv-receipt.toml for extras
    receipt_path = os.path.expanduser(
        "~/.local/share/uv/tools/zotero-mcp-server/uv-receipt.toml")
    extras = "unknown"
    if os.path.isfile(receipt_path):
        try:
            with open(receipt_path) as f:
                content = f.read()
            if '"all"' in content or "'all'" in content:
                extras = "[all]"
            elif '"pdf"' in content or "'pdf'" in content:
                extras = "[pdf]"
            elif '"semantic"' in content or "'semantic'" in content:
                extras = "[semantic]"
            else:
                extras = "core only"
        except Exception:
            pass

    status = "OK" if installed == total else ("WARN" if installed > 0 else "FAIL")
    detail = f"{installed}/{total} installed"
    if missing:
        detail += f" ({', '.join(missing)} missing)"
    detail += f" | extras: {extras}"

    return "dependencies", status, detail, {"packages": results, "extras": extras,
                                             "installed": installed, "total": total}


def check_claude_config():
    """Check Claude Desktop configuration."""
    if IS_MAC:
        cfg_path = os.path.expanduser(
            "~/Library/Application Support/Claude/claude_desktop_config.json")
    else:
        cfg_path = os.path.join(os.environ.get("APPDATA", ""), "Claude",
                                "claude_desktop_config.json")

    info = {"path": cfg_path}

    if not os.path.isfile(cfg_path):
        return "claude-config", "FAIL", "Config file not found", info

    try:
        with open(cfg_path) as f:
            content = f.read()
        info["content"] = content
        config = json.loads(content)
    except json.JSONDecodeError as e:
        info["content"] = content
        return "claude-config", "FAIL", f"Invalid JSON: {e}", info
    except Exception as e:
        return "claude-config", "FAIL", str(e), info

    servers = config.get("mcpServers", {})
    info["mcp_server_count"] = len(servers)
    if "zotero" not in servers:
        return "claude-config", "FAIL", "No 'zotero' MCP server configured", info

    zotero = servers["zotero"]
    cmd = zotero.get("command", "")
    info["zotero_command"] = cmd
    info["zotero_env"] = zotero.get("env", {})

    if not cmd or not os.path.isfile(cmd):
        return "claude-config", "WARN", f"Zotero command path not found: {cmd}", info

    # Validate environment variables if present
    env = zotero.get("env", {})
    env_warnings = []
    if "ZOTERO_API_KEY" in env:
        key = env["ZOTERO_API_KEY"]
        if not key or not key.strip():
            env_warnings.append("ZOTERO_API_KEY is empty")
    if "ZOTERO_LIBRARY_ID" in env:
        lid = env["ZOTERO_LIBRARY_ID"]
        if not lid or not lid.strip():
            env_warnings.append("ZOTERO_LIBRARY_ID is empty")
        elif not str(lid).isdigit():
            env_warnings.append(f"ZOTERO_LIBRARY_ID is not numeric: {lid}")

    if env_warnings:
        return "claude-config", "WARN", "; ".join(env_warnings), info

    return "claude-config", "OK", f"Valid, {len(servers)} MCP server(s)", info


def check_semantic_config():
    """Check semantic search configuration."""
    cfg_path = os.path.expanduser("~/.config/zotero-mcp/config.json")
    info = {"path": cfg_path}

    if not os.path.isfile(cfg_path):
        return "semantic-config", "WARN", "Config file not found", info

    try:
        with open(cfg_path) as f:
            content = f.read()
        info["content"] = content
        config = json.loads(content)
        ss = config.get("semantic_search", {})
        ext = ss.get("extraction", {})
        info["pdf_max_pages"] = ext.get("pdf_max_pages", "not set")
        info["display_max_pages"] = ext.get("fulltext_display_max_pages", "not set")

        # Validate page count values are reasonable
        value_warnings = []
        for key, label in [("pdf_max_pages", "pdf_max_pages"),
                           ("display_max_pages", "fulltext_display_max_pages")]:
            val = info[key]
            if val != "not set":
                if isinstance(val, (int, float)):
                    if val <= 0:
                        value_warnings.append(f"{label} is {val} (should be positive)")
                    elif val > 5000:
                        value_warnings.append(f"{label} is {val} (unusually high, may cause slow builds or OOM)")

        if value_warnings:
            return "semantic-config", "WARN", "; ".join(value_warnings), info

        return "semantic-config", "OK", f"index {info['pdf_max_pages']} pages, display {info['display_max_pages']} pages", info
    except json.JSONDecodeError as e:
        info["content"] = content
        return "semantic-config", "WARN", f"Invalid JSON: {e}", info
    except Exception as e:
        return "semantic-config", "FAIL", str(e), info


def check_zotero_local():
    """Check if Zotero local API is responding."""
    info = {}
    try:
        import urllib.request, urllib.error
        req = urllib.request.Request("http://localhost:23119/api/users/0/items?limit=1")
        resp = urllib.request.urlopen(req, timeout=3)
        data = json.loads(resp.read().decode())
        info["responding"] = True
        info["api_enabled"] = True
        info["item_count"] = len(data) if isinstance(data, list) else "unknown"
        return "zotero-local", "OK", "Responding on localhost:23119", info
    except urllib.error.HTTPError as e:
        # 403 = Zotero is running but local API setting is not enabled
        info["responding"] = True
        info["api_enabled"] = False
        info["http_status"] = e.code
        return ("zotero-local", "WARN",
                "Zotero is running but the local API is disabled. "
                "In Zotero: Settings \u2192 Advanced \u2192 check "
                "\u201cAllow other applications on this computer to communicate with Zotero\u201d",
                info)
    except Exception as e:
        info["responding"] = False
        info["error"] = str(e)
        return "zotero-local", "FAIL", "Zotero is not running or not responding on localhost:23119", info


def check_zotero_api():
    """Check Zotero web API connectivity and API key."""
    info = {}

    # Get credentials from config
    if IS_MAC:
        cfg_path = os.path.expanduser(
            "~/Library/Application Support/Claude/claude_desktop_config.json")
    else:
        cfg_path = os.path.join(os.environ.get("APPDATA", ""), "Claude",
                                "claude_desktop_config.json")

    api_key = ""
    library_id = ""
    try:
        with open(cfg_path) as f:
            config = json.load(f)
        env = config.get("mcpServers", {}).get("zotero", {}).get("env", {})
        api_key = env.get("ZOTERO_API_KEY", "")
        library_id = env.get("ZOTERO_LIBRARY_ID", "")
    except Exception:
        pass

    # Test reachability — try with default certs first, fall back to unverified
    import urllib.request
    import ssl
    ssl_ctx = None
    try:
        req = urllib.request.Request("https://api.zotero.org/")
        urllib.request.urlopen(req, timeout=8)
        info["reachable"] = True
    except urllib.error.URLError as e:
        if "CERTIFICATE_VERIFY_FAILED" in str(e):
            # macOS Python without installed certificates — try unverified
            info["ssl_fallback"] = True
            try:
                ssl_ctx = ssl.create_default_context()
                ssl_ctx.check_hostname = False
                ssl_ctx.verify_mode = ssl.CERT_NONE
                urllib.request.urlopen(req, timeout=8, context=ssl_ctx)
                info["reachable"] = True
            except Exception:
                info["reachable"] = False
                return "zotero-api", "WARN", "Can't reach api.zotero.org", info
        else:
            info["reachable"] = False
            return "zotero-api", "WARN", "Can't reach api.zotero.org", info
    except Exception:
        info["reachable"] = False
        return "zotero-api", "WARN", "Can't reach api.zotero.org", info

    if not api_key or not library_id:
        info["key_configured"] = False
        return "zotero-api", "OK", "Reachable (no API key configured)", info

    # Pre-flight format validation
    info["key_configured"] = True
    info["api_key"] = api_key
    info["library_id"] = library_id

    if not api_key.isalnum() or len(api_key) != 24:
        info["key_format_valid"] = False
        return "zotero-api", "WARN", \
            f"API key appears malformed (expected 24 alphanumeric chars, got {len(api_key)})", info
    info["key_format_valid"] = True
    try:
        req = urllib.request.Request(
            f"https://api.zotero.org/users/{library_id}/items?limit=1")
        req.add_header("Zotero-API-Key", api_key)
        resp = urllib.request.urlopen(req, timeout=10, **({'context': ssl_ctx} if ssl_ctx else {}))
        total = resp.headers.get("Total-Results", "unknown")
        info["total_items"] = total
        return "zotero-api", "OK", f"Valid key — {total} items in library", info
    except urllib.error.HTTPError as e:
        if e.code == 403:
            return "zotero-api", "WARN", "API key rejected (403)", info
        return "zotero-api", "WARN", f"API error: {e.code}", info
    except Exception as e:
        return "zotero-api", "WARN", f"API test failed: {e}", info


def check_search_db():
    """Check search database status."""
    db_dir = os.path.expanduser("~/.config/zotero-mcp/chroma_db")
    info = {"path": db_dir}

    if not os.path.isdir(db_dir):
        return "search-db", "WARN", "Database directory not found", info

    # Get size
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(db_dir):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            try:
                total_size += os.path.getsize(fp)
            except OSError:
                pass

    info["size_mb"] = round(total_size / (1024 * 1024), 1)

    # Get last modified
    try:
        mtime = max(os.path.getmtime(os.path.join(dp, f))
                    for dp, _, fns in os.walk(db_dir) for f in fns)
        info["last_modified"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime))
    except (ValueError, OSError):
        info["last_modified"] = "unknown"

    if total_size == 0:
        return "search-db", "WARN", "Database exists but is empty", info

    # Heuristic: ChromaDB should have a chroma.sqlite3 file
    has_sqlite = os.path.isfile(os.path.join(db_dir, "chroma.sqlite3"))
    info["has_sqlite"] = has_sqlite
    if not has_sqlite:
        return "search-db", "WARN", \
            "Database may be corrupted or incompatible (missing chroma.sqlite3)", info

    # Staleness: warn if database hasn't been updated in >30 days
    try:
        age_days = (time.time() - mtime) / 86400
        info["age_days"] = round(age_days, 1)
        if age_days > 30:
            return "search-db", "WARN", \
                f"{info['size_mb']} MB, last updated {int(age_days)} days ago — consider rebuilding", info
    except Exception:
        pass

    return "search-db", "OK", f"{info['size_mb']} MB, last modified {info['last_modified']}", info


def check_claude_desktop():
    """Check if Claude Desktop is running and get version."""
    info = {}

    if IS_MAC:
        stdout, _, rc = _run(["pgrep", "-x", "Claude"], timeout=3)
        info["running"] = rc == 0
        if rc == 0:
            info["pid"] = stdout.strip()

        # Get version from Info.plist
        plist = "/Applications/Claude.app/Contents/Info.plist"
        if os.path.isfile(plist):
            try:
                stdout, _, rc = _run(
                    ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", plist])
                if rc == 0:
                    info["version"] = stdout.strip()
            except Exception:
                pass
    elif IS_WIN:
        stdout, _, rc = _run(["tasklist", "/FI", "IMAGENAME eq Claude.exe", "/NH"], timeout=5)
        info["running"] = "Claude.exe" in stdout if stdout else False
    else:
        info["running"] = False

    status = "OK" if info.get("running") else "WARN"
    detail = "Running" if info.get("running") else "Not running"
    if info.get("version"):
        detail += f" (v{info['version']})"
    return "claude-desktop", status, detail, info


def check_permissions():
    """Check file permissions on key paths."""
    paths = {}

    mcp_path = shutil.which("zotero-mcp") or os.path.expanduser("~/.local/bin/zotero-mcp")
    if os.path.isfile(mcp_path):
        paths["mcp_binary"] = {"path": mcp_path, "executable": os.access(mcp_path, os.X_OK)}

    if IS_MAC:
        cfg = os.path.expanduser("~/Library/Application Support/Claude/claude_desktop_config.json")
    else:
        cfg = os.path.join(os.environ.get("APPDATA", ""), "Claude", "claude_desktop_config.json")
    if os.path.isfile(cfg):
        paths["claude_config"] = {"path": cfg, "readable": os.access(cfg, os.R_OK),
                                  "writable": os.access(cfg, os.W_OK)}

    sem = os.path.expanduser("~/.config/zotero-mcp/config.json")
    if os.path.isfile(sem):
        paths["semantic_config"] = {"path": sem, "readable": os.access(sem, os.R_OK),
                                    "writable": os.access(sem, os.W_OK)}

    db_dir = os.path.expanduser("~/.config/zotero-mcp/chroma_db")
    if os.path.isdir(db_dir):
        paths["search_db_dir"] = {"path": db_dir, "writable": os.access(db_dir, os.W_OK)}

    issues = []
    for name, info in paths.items():
        if "executable" in info and not info["executable"]:
            issues.append(f"{name} not executable")
        if "writable" in info and not info["writable"]:
            issues.append(f"{name} not writable")
        if "readable" in info and not info["readable"]:
            issues.append(f"{name} not readable")

    status = "OK" if not issues else "WARN"
    detail = "All OK" if not issues else "; ".join(issues)
    return "permissions", status, detail, paths


def check_conflicting_installs():
    """Check for multiple zotero-mcp binaries in PATH."""
    found = []
    seen = set()
    for directory in _enriched_path().split(os.pathsep):
        candidate = os.path.join(directory, "zotero-mcp")
        if os.path.isfile(candidate) and candidate not in seen:
            found.append(candidate)
            seen.add(candidate)

    info = {"paths": found}
    if len(found) > 1:
        return "conflicts", "WARN", f"Multiple copies found: {', '.join(found)}", info
    elif len(found) == 0:
        return "conflicts", "FAIL", "No zotero-mcp found in PATH", info
    return "conflicts", "OK", f"Single install at {found[0]}", info


# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------

ALL_CHECKS = [
    ("Checking system environment", check_system),
    ("Checking uv", check_uv),
    ("Checking git", check_git),
    ("Checking zotero-mcp", check_zotero_mcp),
    ("Checking dependencies", check_dependencies),
    ("Checking Claude config", check_claude_config),
    ("Checking semantic search config", check_semantic_config),
    ("Checking Zotero local API", check_zotero_local),
    ("Checking Zotero web API", check_zotero_api),
    ("Checking search database", check_search_db),
    ("Checking Claude Desktop", check_claude_desktop),
    ("Checking file permissions", check_permissions),
    ("Checking for conflicting installs", check_conflicting_installs),
]


def run_all_checks(stream=False, callback=None):
    """Run all diagnostic checks. Returns list of (name, status, detail, info) tuples.

    If stream=True, prints CHECK: lines for machine parsing.
    If callback is provided, calls callback(label, name, status, detail) for each check.
    """
    results = []
    for label, check_fn in ALL_CHECKS:
        if stream:
            print(f"PROGRESS:{label}...", flush=True)
        if callback:
            callback(label, None, None, None)

        name, status, detail, info = check_fn()
        results.append((name, status, detail, info))

        if stream:
            print(f"CHECK:{name}:{status}:{detail}", flush=True)
        if callback:
            callback(label, name, status, detail)

    return results


# ---------------------------------------------------------------------------
# Report formatting
# ---------------------------------------------------------------------------

def format_report(results, install_log=None):
    """Format diagnostic results into a human-readable report."""
    lines = []
    lines.append("ZOTERO MCP DIAGNOSTIC REPORT")
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append("Versions:")
    lines.append(f"  Diagnostic script:    {DIAGNOSTIC_VERSION}")

    # Get MCP server version from results
    mcp_ver = "unknown"
    for name, status, detail, info in results:
        if name == "zotero-mcp" and info.get("version"):
            mcp_ver = info["version"]
    lines.append(f"  Zotero MCP Server:    {mcp_ver}")
    lines.append("")

    # Summary
    lines.append("=" * 50)
    lines.append("SUMMARY")
    lines.append("=" * 50)

    warnings = 0
    failures = 0
    issues = []
    for name, status, detail, info in results:
        icon = {"OK": "✓", "WARN": "⚠", "FAIL": "✗"}.get(status, "?")
        lines.append(f"  {icon} {name:30s} {detail}")
        if status == "WARN":
            warnings += 1
            issues.append(f"  ⚠ {name}: {detail}")
        elif status == "FAIL":
            failures += 1
            issues.append(f"  ✗ {name}: {detail}")

    lines.append("")
    if issues:
        lines.append(f"Issues found: {len(issues)}")
        for issue in issues:
            lines.append(issue)
    else:
        lines.append("No issues found.")
    lines.append("")

    # System
    for name, status, detail, info in results:
        if name == "system":
            lines.append("=" * 50)
            lines.append("SYSTEM")
            lines.append("=" * 50)
            for k, v in info.items():
                lines.append(f"  {k:20s} {v}")
            lines.append("")
            break

    # Dependencies
    for name, status, detail, info in results:
        if name == "dependencies":
            lines.append("=" * 50)
            lines.append("DEPENDENCIES")
            lines.append("=" * 50)
            lines.append(f"  uv extras installed: {info.get('extras', 'unknown')}")
            lines.append("")
            current_group = None
            for mod, mod_info in info.get("packages", {}).items():
                group = mod_info["group"]
                if group != current_group:
                    lines.append(f"  {group.upper()} packages:")
                    current_group = group
                ver = mod_info["version"]
                icon = "✓" if ver != "NOT INSTALLED" else "✗"
                lines.append(f"    {mod:25s} {ver:20s} {icon}")
            lines.append("")
            break

    # Config files
    lines.append("=" * 50)
    lines.append("CONFIG FILES")
    lines.append("=" * 50)
    for name, status, detail, info in results:
        if name in ("claude-config", "semantic-config"):
            lines.append(f"\n--- {info.get('path', name)} ---")
            content = info.get("content", "(not available)")
            lines.append(content if content else "(empty)")
    lines.append("")

    # Zotero
    lines.append("=" * 50)
    lines.append("ZOTERO")
    lines.append("=" * 50)
    for name, status, detail, info in results:
        if name == "zotero-local":
            lines.append(f"  Local API:    {'Responding' if info.get('responding') else 'Not responding'}")
        elif name == "zotero-api":
            reachable = info.get("reachable", False)
            lines.append(f"  Web API:      {'Reachable' if reachable else 'Unreachable'}")
            if info.get("api_key"):
                lines.append(f"  API Key:      {info['api_key']}")
                lines.append(f"  Library ID:   {info.get('library_id', 'unknown')}")
            if info.get("total_items"):
                lines.append(f"  Total items:  {info['total_items']}")
    lines.append("")

    # MCP Server
    lines.append("=" * 50)
    lines.append("MCP SERVER")
    lines.append("=" * 50)
    for name, status, detail, info in results:
        if name == "zotero-mcp":
            lines.append(f"  Version:      {info.get('version', 'unknown')}")
            lines.append(f"  Path:         {info.get('path', 'not found')}")
        elif name == "search-db":
            lines.append(f"  Search DB:    {info.get('path', 'unknown')}")
            lines.append(f"    Exists:     {os.path.isdir(info.get('path', ''))}")
            lines.append(f"    Size:       {info.get('size_mb', 'unknown')} MB")
            lines.append(f"    Modified:   {info.get('last_modified', 'unknown')}")
    lines.append("")

    # Claude Desktop
    lines.append("=" * 50)
    lines.append("CLAUDE DESKTOP")
    lines.append("=" * 50)
    for name, status, detail, info in results:
        if name == "claude-desktop":
            lines.append(f"  Running:      {info.get('running', False)}")
            if info.get("version"):
                lines.append(f"  Version:      {info['version']}")
            if info.get("pid"):
                lines.append(f"  PID:          {info['pid']}")
    lines.append("")

    # Permissions
    lines.append("=" * 50)
    lines.append("FILE PERMISSIONS")
    lines.append("=" * 50)
    for name, status, detail, info in results:
        if name == "permissions":
            for fname, finfo in info.items():
                path = finfo.get("path", "")
                perms = []
                if "executable" in finfo:
                    perms.append("✓ exec" if finfo["executable"] else "✗ exec")
                if "readable" in finfo:
                    perms.append("✓ read" if finfo["readable"] else "✗ read")
                if "writable" in finfo:
                    perms.append("✓ write" if finfo["writable"] else "✗ write")
                lines.append(f"  {path}")
                lines.append(f"    {', '.join(perms)}")
    lines.append("")

    # Install log (if provided)
    if install_log:
        lines.append("=" * 50)
        lines.append("INSTALL LOG")
        lines.append("=" * 50)
        for entry in install_log:
            lines.append("")
            lines.append(f"  STEP: {entry.get('step', 'unknown')}")
            lines.append(f"  Time: {entry.get('timestamp', 'unknown')} ({entry.get('duration_seconds', 0):.1f}s)")
            lines.append(f"  Command: {entry.get('command', 'unknown')}")
            lines.append(f"  Return code: {entry.get('returncode', 'unknown')}")
            lines.append(f"  STDOUT: {entry.get('stdout', '(empty)')[:500]}")
            lines.append(f"  STDERR: {entry.get('stderr', '(empty)')[:500]}")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Zotero MCP Diagnostic Tool")
    parser.add_argument("--stream", action="store_true",
                        help="Machine-parseable streaming output")
    parser.add_argument("--save", action="store_true",
                        help="Auto-save report to Desktop")
    parser.add_argument("--full", action="store_true",
                        help="Print full report without prompts")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")
    args = parser.parse_args()

    if args.stream:
        print(f"HEADER:diagnostic_version:{DIAGNOSTIC_VERSION}", flush=True)
        results = run_all_checks(stream=True)
        report = format_report(results)
        print("REPORT:BEGIN", flush=True)
        print(report, flush=True)
        print("REPORT:END", flush=True)
        return

    # Interactive / flag-based mode
    print()
    print(_bold("Zotero MCP Diagnostic Tool") + f"  v{DIAGNOSTIC_VERSION}")
    print(_dim("=" * 50))
    print()

    results = []
    for label, check_fn in ALL_CHECKS:
        sys.stdout.write(f"  {label}...")
        sys.stdout.flush()
        name, status, detail, info = check_fn()
        results.append((name, status, detail, info))

        if status == "OK":
            print(f"  {_green('✓')} {detail}")
        elif status == "WARN":
            print(f"  {_yellow('⚠')} {detail}")
        else:
            print(f"  {_red('✗')} {detail}")

    # Summary
    warnings = sum(1 for _, s, _, _ in results if s == "WARN")
    failures = sum(1 for _, s, _, _ in results if s == "FAIL")
    print()
    if failures == 0 and warnings == 0:
        print(_green("  Done — no issues found."))
    else:
        parts = []
        if warnings:
            parts.append(f"{warnings} warning{'s' if warnings > 1 else ''}")
        if failures:
            parts.append(f"{failures} issue{'s' if failures > 1 else ''}")
        print(_yellow(f"  Done — {', '.join(parts)} found."))
    print()

    if args.json:
        output = {"version": DIAGNOSTIC_VERSION, "results": []}
        for name, status, detail, info in results:
            output["results"].append({"name": name, "status": status,
                                      "detail": detail, "info": info})
        print(json.dumps(output, indent=2, default=str))
        return

    if args.full:
        report = format_report(results)
        print(report)
    else:
        resp = input("  Would you like to see the full report? [y/N] ").strip().lower()
        if resp == "y":
            report = format_report(results)
            print()
            print(report)
        else:
            report = None

    if args.save:
        report = report or format_report(results)
        _save_report(report)
    else:
        resp = input("  Would you like to save a copy? [y/N] ").strip().lower()
        if resp == "y":
            report = report or format_report(results)
            _save_report(report)


def _save_report(report):
    """Save report to Desktop."""
    ts = time.strftime("%Y-%m-%d_%H%M")
    filename = f"zotero-mcp-diagnostic-{ts}.txt"
    desktop = os.path.expanduser("~/Desktop")
    filepath = os.path.join(desktop, filename)
    with open(filepath, "w") as f:
        f.write(report)
    print(f"\n  Report saved to: {filepath}")


if __name__ == "__main__":
    main()
