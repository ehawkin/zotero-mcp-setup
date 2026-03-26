#!/usr/bin/env python3
"""
Zotero MCP Server — Graphical Installer (Wizard Style)
Uses PyWebView with HTML/CSS/JS frontend.
Design: Athiti + Ysabeau Office fonts, warm light backgrounds, gold accents.
Includes installation wizard + usage guide screens.
"""

import json
import os
import platform
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import webview
except ImportError:
    print("Installing required package: pywebview...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pywebview", "-q"])
    import webview


class InstallerAPI:
    def __init__(self):
        self.window = None
        self.is_mac = platform.system() == "Darwin"

    def set_window(self, window):
        self.window = window

    def check_prerequisites(self):
        results = {}
        if self.is_mac:
            results["zotero"] = os.path.isdir("/Applications/Zotero.app")
            results["claude"] = os.path.isdir(
                os.path.expanduser("~/Library/Application Support/Claude"))
        else:
            results["zotero"] = any(
                os.path.isfile(os.path.join(p, "Zotero", "zotero.exe"))
                for p in [os.environ.get("ProgramFiles", ""),
                          os.environ.get("ProgramFiles(x86)", ""),
                          os.environ.get("LOCALAPPDATA", "")]
                if p)
            results["claude"] = os.path.isdir(
                os.path.join(os.environ.get("APPDATA", ""), "Claude"))
        results["git"] = shutil.which("git") is not None
        results["uv"] = shutil.which("uv") is not None
        results["existing_credentials"] = self._get_existing_credentials()
        return results

    def _get_existing_credentials(self):
        if self.is_mac:
            cfg = os.path.expanduser(
                "~/Library/Application Support/Claude/claude_desktop_config.json")
        else:
            cfg = os.path.join(os.environ.get("APPDATA", ""), "Claude",
                               "claude_desktop_config.json")
        try:
            with open(cfg) as f:
                c = json.load(f)
            env = c.get("mcpServers", {}).get("zotero", {}).get("env", {})
            key = env.get("ZOTERO_API_KEY", "")
            lid = env.get("ZOTERO_LIBRARY_ID", "")
            if key and lid:
                masked = key[:4] + "***" + key[-4:] if len(key) >= 8 else "***"
                return {"masked_key": masked, "library_id": lid, "raw_key": key}
        except Exception:
            pass
        return None

    def open_url(self, url):
        """Open a URL in the default browser."""
        import webbrowser
        webbrowser.open(url)

    def install(self, config):
        thread = threading.Thread(target=self._run_install, args=(config,), daemon=True)
        thread.start()

    def _js(self, code):
        if self.window:
            self.window.evaluate_js(code)

    def _log(self, msg, level="info"):
        self._js(f'addLog({json.dumps(msg)}, {json.dumps(level)})')

    def _set_progress(self, step, total=5):
        self._js(f'setProgress({step}, {total})')

    def _complete(self, success=True, msg=""):
        self._js(f'showComplete({json.dumps(success)}, {json.dumps(msg)})')

    def _run_install(self, config):
        try:
            api_key = config.get("api_key", "")
            library_id = config.get("library_id", "")
            pdf_index = config.get("pdf_index_pages", 50)
            pdf_display = config.get("pdf_display_pages", 10)
            build_db = config.get("build_db", True)

            # Step 1: uv
            self._set_progress(1)
            self._log("Checking for uv package manager...")
            if shutil.which("uv"):
                self._log("uv is already installed", "success")
            else:
                self._log("Installing uv...")
                cmd = ("curl -LsSf https://astral.sh/uv/install.sh | sh" if self.is_mac
                       else "irm https://astral.sh/uv/install.ps1 | iex")
                shell = ["bash", "-c", cmd] if self.is_mac else ["powershell", "-Command", cmd]
                proc = subprocess.run(shell, capture_output=True, text=True, timeout=120)
                if proc.returncode == 0:
                    os.environ["PATH"] = (os.path.expanduser("~/.local/bin")
                                          + os.pathsep + os.environ.get("PATH", ""))
                    self._log("uv installed", "success")
                else:
                    self._log("Failed to install uv", "error")
                    self._complete(False, "Could not install uv.")
                    return

            # Step 2: Server
            self._set_progress(2)
            self._log("Installing Zotero MCP server...")
            self._log("This may take a minute or two...")
            uv = shutil.which("uv") or os.path.expanduser("~/.local/bin/uv")
            pkg = "zotero-mcp-server[all]"
            proc = subprocess.run([uv, "tool", "install", "--force", "--reinstall", pkg],
                                  capture_output=True, text=True, timeout=300)
            if proc.returncode == 0:
                self._log("Server installed", "success")
            else:
                self._log(f"Install error: {proc.stderr[:200]}", "error")
                self._complete(False, "Server installation failed.")
                return

            mcp_path = shutil.which("zotero-mcp") or os.path.expanduser("~/.local/bin/zotero-mcp")
            if not os.path.isfile(mcp_path):
                self._complete(False, "Could not find zotero-mcp after installation.")
                return

            # Step 3: Claude config
            self._set_progress(3)
            self._log("Configuring Claude Desktop...")
            if self.is_mac:
                cfg_dir = os.path.expanduser("~/Library/Application Support/Claude")
            else:
                cfg_dir = os.path.join(os.environ.get("APPDATA", ""), "Claude")
            cfg_file = os.path.join(cfg_dir, "claude_desktop_config.json")
            os.makedirs(cfg_dir, exist_ok=True)

            if os.path.isfile(cfg_file):
                ts = time.strftime("%Y-%m-%d_%H%M")
                shutil.copy2(cfg_file, cfg_file.replace(".json", f"_backup_{ts}.json"))
                self._log("Config backed up", "success")

            existing = {}
            if os.path.isfile(cfg_file):
                try:
                    with open(cfg_file) as f:
                        existing = json.load(f)
                except Exception:
                    pass

            env_vars = {"ZOTERO_LOCAL": "true"}
            if api_key and library_id:
                env_vars.update({"ZOTERO_API_KEY": api_key,
                                 "ZOTERO_LIBRARY_ID": library_id,
                                 "ZOTERO_LIBRARY_TYPE": "user"})

            existing.setdefault("mcpServers", {})
            existing["mcpServers"]["zotero"] = {"command": mcp_path, "env": env_vars}
            with open(cfg_file, "w") as f:
                json.dump(existing, f, indent=2)
                f.write("\n")

            mode = "hybrid (read + write)" if api_key else "local-only (read)"
            self._log(f"Configured: {mode} mode", "success")

            # Step 4: Semantic search
            self._set_progress(4)
            self._log("Setting up semantic search...")
            sem_dir = os.path.expanduser("~/.config/zotero-mcp")
            sem_file = os.path.join(sem_dir, "config.json")
            os.makedirs(sem_dir, exist_ok=True)

            sem = {}
            if os.path.isfile(sem_file):
                try:
                    with open(sem_file) as f:
                        sem = json.load(f)
                except Exception:
                    pass

            ss = sem.setdefault("semantic_search", {})
            ss.setdefault("update_config", {}).update(
                {"auto_update": True, "update_frequency": "startup"})
            ss.setdefault("extraction", {}).update(
                {"pdf_max_pages": pdf_index, "fulltext_display_max_pages": pdf_display})

            with open(sem_file, "w") as f:
                json.dump(sem, f, indent=2)
                f.write("\n")
            self._log(f"Search: index {pdf_index}pp, display {pdf_display}pp", "success")

            # Step 5: Database
            if build_db:
                self._set_progress(5)
                self._log("Building search database (may take several minutes)...")
                env = os.environ.copy()
                env["ZOTERO_LOCAL"] = "true"
                proc = subprocess.run([mcp_path, "update-db", "--fulltext"],
                                      env=env, capture_output=True, text=True, timeout=1800)
                if proc.returncode == 0:
                    self._log("Database built", "success")
                else:
                    self._log("Database build had issues — will auto-build later", "warning")
            else:
                self._set_progress(5)
                self._log("Skipping database (will auto-build on first use)", "info")

            self._complete(True)

        except subprocess.TimeoutExpired:
            self._complete(False, "Operation timed out. Please try again.")
        except Exception as e:
            self._complete(False, str(e))


# ---------------------------------------------------------------------------
# HTML/CSS/JS — Wizard UI with Guide
# ---------------------------------------------------------------------------

HTML = r"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<link href="https://fonts.googleapis.com/css2?family=Athiti:wght@500;600&family=Ysabeau+Office:wght@400;500;600&display=swap" media="print" onload="this.media='all'"" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Ysabeau Office',-apple-system,sans-serif;background:#FEFBF6;color:#20262E;
  min-height:100vh;display:flex;justify-content:center;padding:20px 16px}
.container{max-width:540px;width:100%}
.header{display:flex;align-items:center;gap:14px;margin-bottom:18px}
.header img{width:56px;height:56px;border-radius:12px}
.header-text h1{font-family:'Athiti',sans-serif;font-weight:600;font-size:22px}
.header-text p{font-size:12.5px;color:rgba(32,38,46,.45)}
.card{background:#fff;border:1px solid rgba(32,38,46,.07);border-radius:13px;padding:22px;
  margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.03)}
.card h2{font-family:'Athiti',sans-serif;font-weight:600;font-size:16px;margin-bottom:10px}
.card p{font-size:13px;color:rgba(32,38,46,.6);line-height:1.6;margin-bottom:8px}
.prereq-row{display:flex;align-items:center;padding:5px 0;font-size:13px}
.prereq-dot{width:18px;height:18px;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-size:11px;margin-right:9px;flex-shrink:0}
.prereq-dot.ok{background:#BECEC5;color:#20262E}
.prereq-dot.no{background:#f0d0c0;color:#20262E}
.prereq-dot.wait{background:#FECF75;color:#20262E}
label{display:block;font-size:12px;color:rgba(32,38,46,.45);margin:10px 0 4px}
input[type=text],input[type=password],select{width:100%;padding:9px 11px;background:#F7F7F7;
  border:1px solid rgba(32,38,46,.1);border-radius:7px;color:#20262E;font-size:13px;
  font-family:'Ysabeau Office',sans-serif;outline:none}
input:focus,select:focus{border-color:#D8D0C0}
.btn{display:inline-block;padding:10px 20px;border-radius:8px;font-size:13.5px;font-weight:500;
  cursor:pointer;border:none;font-family:'Ysabeau Office',sans-serif;transition:all .15s}
.btn-primary{background:#20262E;color:#fff;width:100%;padding:11px;font-size:14px}
.btn-primary:hover{background:#333a44}
.btn-primary:disabled{opacity:.35;cursor:not-allowed}
.btn-outline{background:transparent;color:#20262E;border:1px solid rgba(32,38,46,.15);font-size:12.5px;padding:7px 14px}
.btn-outline:hover{background:rgba(32,38,46,.03)}
.btn-row{display:flex;gap:8px;margin-top:14px}
.btn-row .btn{flex:1}
.nav-row{display:flex;justify-content:space-between;align-items:center;margin-top:14px}
.back-link{font-size:13px;color:rgba(32,38,46,.4);cursor:pointer;display:flex;align-items:center;gap:4px}
.back-link:hover{color:#20262E}
.radio-option{display:flex;align-items:flex-start;gap:12px;padding:12px;margin:6px 0;
  border:2px solid rgba(32,38,46,.08);border-radius:10px;cursor:pointer;transition:all .2s}
.radio-option:hover{border-color:rgba(254,207,117,.4);background:rgba(254,207,117,.03)}
.radio-option.selected{border-color:#FECF75;background:rgba(254,207,117,.06)}
.radio-dot{width:18px;height:18px;border-radius:50%;border:2px solid rgba(32,38,46,.2);
  display:flex;align-items:center;justify-content:center;flex-shrink:0;margin-top:1px;transition:all .2s}
.radio-option.selected .radio-dot{border-color:#FECF75}
.radio-inner{width:9px;height:9px;border-radius:50%;background:transparent;transition:all .2s}
.radio-option.selected .radio-inner{background:#FECF75}
.radio-content{flex:1}
.radio-label{font-weight:600;font-size:13.5px;margin-bottom:2px}
.radio-desc{font-size:12px;color:rgba(32,38,46,.5);line-height:1.5}
.toggle-row{display:flex;background:#F7F7F7;border-radius:8px;padding:3px;margin-bottom:14px}
.toggle-opt{flex:1;text-align:center;padding:7px 12px;border-radius:6px;font-size:12.5px;
  cursor:pointer;transition:all .2s;color:rgba(32,38,46,.5)}
.toggle-opt.active{background:#fff;color:#20262E;font-weight:500;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.check-row{display:flex;align-items:center;font-size:13px;margin-top:8px;cursor:pointer}
.check-row input{margin-right:7px;accent-color:#20262E}
.cred-box{background:#F5F1ED;border-radius:7px;padding:12px;margin-bottom:10px;font-size:12.5px;line-height:1.6}
.cred-box strong{font-weight:600}
.step-dots{display:flex;justify-content:center;gap:6px;margin-bottom:16px}
.step-dot{width:7px;height:7px;border-radius:50%;background:rgba(32,38,46,.1);transition:all .3s}
.step-dot.active{background:#FECF75;width:18px;border-radius:4px}
.step-dot.done{background:#BECEC5}
.log-area{background:#F7F7F7;border-radius:7px;padding:12px;max-height:180px;overflow-y:auto;
  font-family:'SF Mono','Menlo',monospace;font-size:11px;line-height:1.7}
.log-line.success{color:#2d6a4f}.log-line.error{color:#9a3030}
.log-line.warning{color:#8a6d20}.log-line.info{color:rgba(32,38,46,.55)}
.progress-bar{height:4px;background:rgba(32,38,46,.06);border-radius:2px;margin:12px 0;overflow:hidden}
.progress-fill{height:100%;background:#FECF75;border-radius:2px;transition:width .5s}
.important{background:#FFF8E8;border:1px solid #FECF75;border-radius:9px;padding:12px;
  margin-top:12px;text-align:left;font-size:12px;line-height:1.6}
.important strong{color:#20262E}
.screen{display:none}.screen.active{display:block}
.link{color:#20262E;text-decoration:underline;cursor:pointer}
.hint{font-size:11px;color:rgba(32,38,46,.35);margin-top:3px}
.hidden{display:none}
.info-btn{display:inline-flex;align-items:center;justify-content:center;width:16px;height:16px;
  border-radius:50%;background:rgba(32,38,46,.08);font-size:10px;cursor:pointer;margin-left:4px;
  color:rgba(32,38,46,.4);border:none;font-family:serif;vertical-align:middle}
.info-btn:hover{background:rgba(32,38,46,.15)}
.info-panel{background:#F5F1ED;border-radius:8px;padding:12px;margin:10px 0;font-size:12px;
  line-height:1.6;color:rgba(32,38,46,.6)}
.separator{border-top:1px solid rgba(32,38,46,.06);margin:14px 0}
.guide-section{margin-bottom:10px}
.guide-section h3{font-family:'Athiti',sans-serif;font-size:14px;font-weight:600;margin-bottom:4px}
.guide-section p{font-size:12.5px;color:rgba(32,38,46,.6);line-height:1.6}
.example{background:#F7F7F7;border-radius:6px;padding:8px 10px;font-size:12px;
  color:rgba(32,38,46,.7);margin:4px 0;font-style:italic;line-height:1.5}
.badge{font-size:10px;color:#BECEC5;font-weight:500;background:rgba(190,206,197,.15);
  padding:2px 7px;border-radius:4px;margin-left:5px}
</style>
</head>
<body>
<div id="loading" style="display:flex;justify-content:center;align-items:center;height:100vh;flex-direction:column;gap:12px">
  <div style="width:40px;height:40px;border:3px solid rgba(32,38,46,.1);border-top-color:#FECF75;border-radius:50%;animation:spin 0.8s linear infinite"></div>
  <div style="font-size:13px;color:rgba(32,38,46,.4)">Loading...</div>
</div>
<style>@keyframes spin{to{transform:rotate(360deg)}}</style>
<div class="container" id="main-content" style="display:none">

<div class="header">
  <img src="data:image/png;base64,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" alt="Zotero MCP">
  <div class="header-text">
    <h1>Zotero MCP Setup</h1>
    <p>Connect your Zotero library to Claude</p>
  </div>
</div>

<div class="step-dots" id="step-dots">
  <div class="step-dot active" id="dot-0"></div>
  <div class="step-dot" id="dot-1"></div>
  <div class="step-dot" id="dot-2"></div>
  <div class="step-dot" id="dot-3"></div>
  <div class="step-dot" id="dot-4"></div>
</div>

<!-- S0: Welcome + Prerequisites -->
<div class="screen active" id="screen-0">
  <div class="card">
    <p>This gives Claude the ability to:</p>
    <div style="font-size:12.5px;color:rgba(32,38,46,.6);line-height:1.7;padding:4px 0 4px 6px">
      • Search and browse your papers by keyword, author, or topic<br>
      • Read and discuss the content of your papers<br>
      • Add new papers by DOI, URL, or file<br>
      • Manage collections, tags, and notes<br>
      • Find and merge duplicates<br>
      • Highlight and annotate PDFs
    </div>
    <div class="separator"></div>
    <h2 style="font-size:14px">Prerequisites</h2>
    <div id="prereq-list"><div class="prereq-row"><div class="prereq-dot wait">...</div>Checking...</div></div>
  </div>
  <button class="btn btn-primary" id="btn-start" disabled onclick="goTo(1)">Continue</button>
</div>

<!-- S1: Mode Selection -->
<div class="screen" id="screen-1">
  <div class="card">
    <h2>How would you like to set up?</h2>
    <div class="radio-option selected" id="opt-default" onclick="selectMode('default')">
      <div class="radio-dot"><div class="radio-inner"></div></div>
      <div class="radio-content">
        <div class="radio-label">Default <span class="badge">recommended</span></div>
        <div class="radio-desc">Hybrid mode with semantic search. Just enter your API key and you’re ready.</div>
      </div>
    </div>
    <div class="radio-option" id="opt-advanced" onclick="selectMode('advanced')">
      <div class="radio-dot"><div class="radio-inner"></div></div>
      <div class="radio-content">
        <div class="radio-label">Advanced</div>
        <div class="radio-desc">Choose access mode, configure search & PDF settings.</div>
      </div>
    </div>
  </div>
  <div class="nav-row">
    <span class="back-link" onclick="goTo(0)">← Back</span>
    <button class="btn btn-primary" style="width:auto;padding:10px 28px" onclick="goToAfterMode()">Continue</button>
  </div>
</div>

<!-- S2: API Credentials -->
<div class="screen" id="screen-2">
  <div class="card">
    <h2>Zotero API Access <button class="info-btn" onclick="toggleInfo()">i</button></h2>
    <p>A free API key enables write operations — adding papers, managing collections, and more.</p>

    <div id="info-panel" class="info-panel hidden">
      <strong>How to get your API key:</strong><br>
      1. Go to <span class="link" onclick="pywebview.api.open_url('https://www.zotero.org/settings/keys')">zotero.org/settings/keys</span><br>
      2. You may need to log in first. If you haven’t verified your email, do that too.<br>
      3. Click “Create new private key”<br>
      4. Name it (e.g., “Claude MCP”)<br>
      5. Under “Personal Library”, check: Allow library access, Allow write access, Allow notes access<br>
      6. Click “Save Key” and copy the key<br><br>
      <strong>Your User ID</strong> is the number labeled “Your userID for use in API calls” on the same page — it’s NOT your username.
    </div>

    <div id="cred-existing" class="hidden">
      <div class="cred-box">
        <strong>Existing credentials found in your config file:</strong><br>
        API Key: <span id="ex-key"></span><br>
        User ID: <span id="ex-id"></span>
      </div>
      <div class="toggle-row">
        <div class="toggle-opt active" id="tog-existing" onclick="toggleCreds('existing')">Use existing</div>
        <div class="toggle-opt" id="tog-new" onclick="toggleCreds('new')">Enter new</div>
      </div>
    </div>

    <div id="cred-fields">
      <label>API Key <span style="color:rgba(32,38,46,.25)">(leave blank for read-only mode)</span></label>
      <input type="text" id="api-key" placeholder="Paste API key...">
      <label>User ID</label>
      <input type="text" id="library-id" placeholder="Numeric user ID">
      <p class="hint">Find this at <span class="link" onclick="pywebview.api.open_url('https://www.zotero.org/settings/keys')">zotero.org/settings/keys</span></p>
    </div>
  </div>
  <div class="nav-row">
    <span class="back-link" onclick="goTo(1)">← Back</span>
    <button class="btn btn-primary" style="width:auto;padding:10px 28px" onclick="continueFromCreds()">Continue</button>
  </div>
</div>

<!-- S3: Advanced Settings -->
<div class="screen" id="screen-3">
  <div class="card">
    <h2>Search & Reading Settings</h2>
    <label>Pages to index for semantic search</label>
    <select id="pdf-index">
      <option value="10">10 — fast build</option>
      <option value="20">20 — moderate</option>
      <option value="50" selected>50 — thorough (recommended)</option>
    </select>
    <p class="hint">Uses a local AI model — no tokens consumed.</p>
    <label>Pages Claude can read per paper</label>
    <select id="pdf-display">
      <option value="10" selected>10 — saves usage (recommended)</option>
      <option value="20">20 — balanced</option>
      <option value="50">50 — thorough</option>
    </select>
    <p class="hint">More pages = better understanding but uses more Claude allowance.</p>
    <div class="separator"></div>
    <h2 style="font-size:14px">Search Database</h2>
    <p>Building the database indexes your papers for semantic search (finding papers by meaning). This is a one-time process that takes 5\u201315 minutes. After that, it updates automatically.</p>
    <div class="check-row"><input type="checkbox" id="build-db" checked>
      <label for="build-db" style="margin:0;cursor:pointer;font-size:13px">Build now (recommended)</label></div>
    <p class="hint" style="margin-top:6px">You can always build later by re-running this installer.</p>
  </div>
  <div class="nav-row">
    <span class="back-link" onclick="goTo(2)">← Back</span>
    <button class="btn btn-primary" style="width:auto;padding:10px 28px" onclick="goTo(4)">Install</button>
  </div>
</div>

<!-- S4: Installing -->
<div class="screen" id="screen-4">
  <div class="card">
    <h2>Installing...</h2>
    <div class="progress-bar"><div class="progress-fill" id="progress-fill" style="width:0%"></div></div>
    <div class="log-area" id="log-area"></div>
  </div>
</div>

<!-- S5: Complete + Guide -->
<div class="screen" id="screen-5">
  <div class="card">
    <div id="complete-box"></div>
  </div>
  <div class="card hidden" id="guide-card">
    <h2>How to Use</h2>
    <div class="guide-section">
      <h3>Getting Started</h3>
      <p>1. Make sure Zotero is open<br>2. Open Claude Desktop (restart if already open)<br>3. Start chatting!</p>
    </div>
    <div class="guide-section">
      <h3>Example Prompts</h3>
      <div class="example">“What papers are in my library about mindfulness and depression?”</div>
      <div class="example">“Find the paper by Kabat-Zinn from 2003”</div>
      <div class="example">“Add this paper by DOI: 10.1038/nature12373”</div>
      <div class="example">“Create a collection called Thesis Research and add my recent papers”</div>
      <div class="example">“Highlight key findings in the Wang 2025 paper”</div>
    </div>
    <div class="guide-section">
      <h3>Usage Tips</h3>
      <p>Reading full papers uses significant Claude allowance. Search by topic rather than reading whole papers. Use Sonnet for extracting data; Opus for critical analysis.</p>
    </div>
  </div>
</div>
</div>

<script>
let cur=0,selectedMode='default',useExKey='',useExId='',credMode='existing';

function goTo(n){
  document.getElementById('screen-'+cur).classList.remove('active');
  document.getElementById('screen-'+n).classList.add('active');
  for(let i=0;i<=4;i++){const d=document.getElementById('dot-'+i);d.classList.remove('active','done');
    if(i<n)d.classList.add('done');else if(i===n)d.classList.add('active')}
  cur=n;if(n===4)startInstall()
}

function selectMode(m){selectedMode=m;
  document.getElementById('opt-default').classList.toggle('selected',m==='default');
  document.getElementById('opt-advanced').classList.toggle('selected',m==='advanced')}

function goToAfterMode(){goTo(2)}

function continueFromCreds(){
  // Validation: if entering new creds, check fields (unless blank = read-only)
  var key=document.getElementById('api-key').value.trim();
  var lid=document.getElementById('library-id').value.trim();
  if(credMode==='new' || !useExKey){
    if(key && !lid){alert('Please enter your User ID, or leave both fields blank for read-only mode.');return}
  }
  // Default mode goes to install; Advanced goes to settings
  if(selectedMode==='default'){goTo(4)}else{goTo(3)}
}

function toggleCreds(mode){credMode=mode;
  document.getElementById('tog-existing').classList.toggle('active',mode==='existing');
  document.getElementById('tog-new').classList.toggle('active',mode==='new');
  if(mode==='existing'){
    document.getElementById('api-key').value=useExKey;
    document.getElementById('library-id').value=useExId;
    document.getElementById('cred-fields').classList.add('hidden');
  }else{
    document.getElementById('api-key').value='';
    document.getElementById('library-id').value='';
    document.getElementById('cred-fields').classList.remove('hidden');
  }
}

function toggleInfo(){document.getElementById('info-panel').classList.toggle('hidden')}

function startInstall(){
  var key=document.getElementById('api-key').value.trim();
  var lid=document.getElementById('library-id').value.trim();
  if(credMode==='existing' && useExKey){key=useExKey;lid=useExId}
  pywebview.api.install({api_key:key,library_id:lid,
    pdf_index_pages:parseInt(document.getElementById('pdf-index').value),
    pdf_display_pages:parseInt(document.getElementById('pdf-display').value),
    build_db:document.getElementById('build-db').checked})
}

function addLog(m,l){const a=document.getElementById('log-area'),d=document.createElement('div');
  d.className='log-line '+l;d.textContent=(l==='success'?'✓ ':l==='error'?'✗ ':l==='warning'?'⚠ ':'')+m;
  a.appendChild(d);a.scrollTop=a.scrollHeight}

function setProgress(s,t){document.getElementById('progress-fill').style.width=Math.round(s/t*100)+'%'}

function showComplete(ok,msg){goTo(5);const b=document.getElementById('complete-box');
  if(ok){b.innerHTML='<h2 style="color:#2d6a4f">✓ Setup Complete!</h2>'+
    '<p style="font-size:13px;color:rgba(32,38,46,.6)">Restart Claude Desktop and start chatting!</p>'+
    '<div class="important"><strong>Important:</strong> In Zotero, go to <strong>Settings → Advanced</strong> '+
    'and check:<br><br><strong>☑ Allow other applications on this computer to communicate with Zotero</strong>'+
    '<br><br>Without this, the MCP cannot connect.</div>';
    document.getElementById('guide-card').classList.remove('hidden')}
  else{b.innerHTML='<h2 style="color:#9a3030">Setup Failed</h2>'+
    '<p style="font-size:13px;color:rgba(32,38,46,.6)">'+msg+'</p>'+
    '<div style="margin-top:12px"><button class="btn btn-outline" onclick="location.reload()">Try Again</button></div>'}
}

window.addEventListener('pywebviewready',function(){
  document.getElementById('loading').style.display='none';
  document.getElementById('main-content').style.display='block';
  pywebview.api.check_prerequisites().then(function(r){
    const l=document.getElementById('prereq-list');l.innerHTML='';
    [{k:'zotero',n:'Zotero 8',u:'https://www.zotero.org/download'},
     {k:'claude',n:'Claude Desktop',u:'https://claude.ai/download'},
     {k:'git',n:'Git'},{k:'uv',n:'uv (auto-install)',a:true}].forEach(function(it){
      const ok=r[it.k],cls=ok?'ok':(it.a?'wait':'no'),ico=ok?'✓':(it.a?'↓':'✗');
      let ex='';if(!ok&&it.u)ex=' — <a href="javascript:void(0)" class="link" onclick="pywebview.api.open_url(\''+it.u+'\')">Download</a>';
      if(!ok&&it.a)ex=' — installs automatically';
      const d=document.createElement('div');d.className='prereq-row';
      d.innerHTML='<div class="prereq-dot '+cls+'">'+ico+'</div><span>'+it.n+ex+'</span>';
      l.appendChild(d)});
    document.getElementById('btn-start').disabled=false;
    if(r.existing_credentials){useExKey=r.existing_credentials.raw_key||'';
      useExId=r.existing_credentials.library_id;
      document.getElementById('ex-key').textContent=useExKey;
      document.getElementById('ex-id').textContent=useExId;
      document.getElementById('cred-existing').classList.remove('hidden');
      document.getElementById('cred-fields').classList.add('hidden');
      document.getElementById('api-key').value=useExKey;
      document.getElementById('library-id').value=useExId}
  })
})
</script>
</body></html>"""


def main():
    api = InstallerAPI()
    window = webview.create_window(
        "Zotero MCP Setup",
        html=HTML,
        width=580,
        height=720,
        resizable=True,
        js_api=api,
        background_color="#FEFBF6"
    )
    api.set_window(window)
    webview.start(debug=False)


if __name__ == "__main__":
    main()
