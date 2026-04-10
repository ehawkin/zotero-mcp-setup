#!/bin/bash

# =============================================================================
# Zotero MCP Server Installer for macOS
# Connects your Zotero research library to Claude and other AI assistants
#
# Uses 'uv' (the recommended installer) — no Python or pip required.
# If uv is not installed, the script installs it automatically.
#
# Usage: bash install-zotero-mcp.sh
#        bash install-zotero-mcp.sh -eugene   (install from Eugene's fork)
# Do NOT run with sudo.
# Press Ctrl+C at any time to quit.
# =============================================================================

# Check flags
USE_FORK=false
RUN_DIAGNOSE=false
for arg in "$@"; do
    if [[ "$arg" == "-eugene" ]]; then
        USE_FORK=true
    elif [[ "$arg" == "--diagnose" ]]; then
        RUN_DIAGNOSE=true
    fi
done

# --diagnose: run diagnostics only, no install
if [[ "$RUN_DIAGNOSE" == true ]]; then
    if ! command -v python3 &>/dev/null; then
        echo "Error: Python 3 is required to run diagnostics."
        exit 1
    fi
    DIAG_SCRIPT=$(mktemp /tmp/zotero-mcp-diagnostic.XXXXXX.py)
    trap "rm -f '$DIAG_SCRIPT'" EXIT
    curl -sL "https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/zotero-mcp-diagnostic.py" -o "$DIAG_SCRIPT" 2>/dev/null
    if [[ ! -s "$DIAG_SCRIPT" ]]; then
        echo "Error: Could not download diagnostic script. Check your internet connection."
        exit 1
    fi
    python3 "$DIAG_SCRIPT" "$@"
    exit $?
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
fail()    { echo -e "${RED}  ✗${NC} $1"; }

# UX helpers
pause()   { sleep "${1:-0.5}"; }  # Brief pause between sections
section() { echo ""; echo -e "${CYAN}━━ $1 ━━${NC}"; echo ""; pause 0.3; }

# Spinner for long-running operations
spin() {
    local pid=$1
    local msg="${2:-Working...}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BLUE}%s${NC} %s" "${chars:i%${#chars}:1}" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r%*s\r" $((${#msg} + 6)) ""  # Clear spinner line
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          Zotero MCP Server — Installation Script         ║${NC}"
echo -e "${BOLD}║                                                          ║${NC}"
echo -e "${BOLD}║  This script installs the Zotero MCP server, which       ║${NC}"
echo -e "${BOLD}║  connects your Zotero library to Claude and other AI     ║${NC}"
echo -e "${BOLD}║  assistants.                                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# STEP 1: Prerequisites
# ============================================================================

section "Checking Prerequisites"

# Check we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    fail "This script is for macOS only."
    exit 1
fi

# --- Check for Zotero ---
ZOTERO_FOUND=true
if [[ -d "/Applications/Zotero.app" ]]; then
    success "Zotero desktop app found"
else
    ZOTERO_FOUND=false
    echo ""
    warn "Zotero was not detected on this computer."
    echo ""
    echo "   For the full experience, the MCP server requires Zotero 8."
    echo "   Download it from: https://www.zotero.org/download"
    echo ""
    echo "   If you continue without Zotero, the server will be installed"
    echo "   in Web API-only mode. This provides basic search and library"
    echo "   management but does NOT include:"
    echo "     • Semantic search (find papers by meaning)"
    echo "     • PDF reading, annotation, and outline extraction"
    echo "     • Full-text paper access"
    echo "     • RSS feed access"
    echo ""
    echo "   Install Zotero first, then press Y to continue — or re-run"
    echo "   this script when you're ready."
    echo ""
    read -p "   Continue with Web API-only mode? (y/N)  [Ctrl+C to quit] " -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo ""; info "Install Zotero first, then re-run this script."; exit 0; }
fi

# --- Check for Claude Desktop ---
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

if [[ -d "$CLAUDE_CONFIG_DIR" ]]; then
    success "Claude Desktop found"
else
    echo ""
    warn "Claude Desktop was not found."
    echo ""
    echo "   Download it from: https://claude.ai/download"
    echo ""
    echo "   After installing, press Y to continue — or re-run"
    echo "   this script when you're ready."
    echo ""
    read -p "   Continue? (y/N)  [Ctrl+C to quit] " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Install Claude Desktop, then re-run this script."
        exit 0
    fi
    # Create the config directory if user wants to continue
    mkdir -p "$CLAUDE_CONFIG_DIR"
fi

# --- Check for Git ---
if command -v git &>/dev/null; then
    success "Git is available"
else
    # Check Homebrew locations before triggering Xcode install
    HOMEBREW_GIT=""
    for git_candidate in /opt/homebrew/bin/git /usr/local/bin/git; do
        if [[ -x "$git_candidate" ]]; then
            HOMEBREW_GIT="$git_candidate"
            break
        fi
    done

    if [[ -n "$HOMEBREW_GIT" ]]; then
        export PATH="$(dirname "$HOMEBREW_GIT"):$PATH"
        success "Git found at $HOMEBREW_GIT"
    else
        echo ""
        warn "Git is not installed. It's needed to download the server."
        echo ""
        echo "   We'll open the macOS developer tools installer for you."
        echo "   A dialog box will appear — click \"Install\" and wait for"
        echo "   it to finish (this downloads about 1.5 GB and may take"
        echo "   5-10 minutes depending on your internet speed)."
        echo ""
        echo "   If the installer doesn't appear, or the download fails, you can"
        echo "   download Command Line Tools directly from Apple:"
        echo "   https://developer.apple.com/download/all/"
        echo "   (search for \"Command Line Tools\")"
        echo ""
        echo "   Once the install completes, come back to this terminal"
        echo "   window."
        echo ""
        read -p "   Press Enter to open the installer... " -r
        echo ""

        xcode-select --install 2>/dev/null || true

        echo ""
        echo "   Waiting for developer tools installation to complete..."
        echo "   (This script will continue automatically when it detects"
        echo "    the installation is complete. You can also press Enter"
        echo "    to check manually.)"
        echo ""

        while true; do
            # Check every 3 seconds, but also accept Enter
            read -t 3 -r USER_INPUT 2>/dev/null || true

            if xcode-select -p &>/dev/null; then
                success "Developer tools installed successfully. Continuing..."
                break
            fi

            if [[ -n "$USER_INPUT" ]]; then
                if [[ "$USER_INPUT" =~ ^[Qq]$ ]]; then
                    echo ""
                    echo "   Git is required to continue. To install it:"
                    echo ""
                    echo "   Option 1: Re-run this script (it will try the installer again)"
                    echo "   Option 2: Open Terminal and run: xcode-select --install"
                    echo "   Option 3: Install Git directly from https://git-scm.com/download/mac"
                    echo "   Option 4: Download Command Line Tools from Apple:"
                    echo "             https://developer.apple.com/download/all/"
                    echo "             (search for \"Command Line Tools\")"
                    echo ""
                    echo "   After installing, re-run this script."
                    exit 1
                fi

                # User pressed Enter but tools not ready
                if ! xcode-select -p &>/dev/null; then
                    warn "Installation not complete yet. Still waiting..."
                    echo "      Press Q to quit and troubleshoot, or keep waiting."
                fi
            fi
        done
    fi
fi

# ============================================================================
# STEP 2: Installation Mode
# ============================================================================

echo ""

# Defaults
SETUP_MODE="1"
ZOTERO_API_KEY=""
ZOTERO_LIBRARY_ID=""
ENABLE_WRITE_SUPPORT=""
ACCESS_MODE="hybrid"
BUILD_SEMANTIC_DB="yes"
ENABLE_SEMANTIC_SEARCH="yes"
PDF_INDEX_PAGES="50"
PDF_DISPLAY_PAGES="10"

# If Zotero not found, force web API mode
if [[ "$ZOTERO_FOUND" == false ]]; then
    info "Zotero not installed — configuring Web API-only mode."
    ACCESS_MODE="web"
    BUILD_SEMANTIC_DB="no"
    ENABLE_SEMANTIC_SEARCH="no"
    ENABLE_WRITE_SUPPORT="true"
else
    echo "  How would you like to configure the installation?"
    echo ""
    echo "    1) Default (recommended)"
    echo "       Hybrid mode: fast local reads + web API for writes"
    echo "       Semantic search enabled with standard settings"
    echo ""
    echo "    2) Advanced"
    echo "       Choose your access mode and customize settings"
    echo ""
    read -p "  Press 1 or 2: " -n 1 SETUP_MODE
    echo ""
fi

# --- Advanced mode options ---
if [[ "$SETUP_MODE" == "2" ]]; then

    # Access mode
    section "Access Mode"
    echo ""
    echo "  How should the MCP connect to Zotero?"
    echo ""
    echo "    1) Hybrid (recommended)"
    echo "       Reads from local Zotero (fast), writes via web API"
    echo "       Requires: Zotero running + API key"
    echo ""
    echo "    2) Local only"
    echo "       Reads from local Zotero, no write operations"
    echo "       Requires: Zotero running"
    echo ""
    echo "    3) Web API only"
    echo "       Everything through Zotero's cloud API"
    echo "       Works without Zotero running, but slower and limited:"
    echo "       no semantic search, PDF features, or full-text access"
    echo ""
    read -p "  Press 1, 2, or 3: " -n 1 ACCESS_CHOICE
    echo ""

    case "$ACCESS_CHOICE" in
        2) ACCESS_MODE="local" ;;
        3) ACCESS_MODE="web"; ENABLE_SEMANTIC_SEARCH="no"; BUILD_SEMANTIC_DB="no" ;;
        *) ACCESS_MODE="hybrid" ;;
    esac

    # Semantic search
    if [[ "$ACCESS_MODE" != "web" ]]; then
        section "Semantic Search Settings"
        echo ""
        echo "  Semantic search lets you find papers by meaning, not just keywords."
        echo "  For example: \"papers about the relationship between sleep and memory\""
        echo ""
        echo "  By default, it uses a small local AI model that runs on your"
        echo "  computer — no tokens or usage limits are consumed."
        echo ""
        echo "  Recommended: Yes"
        read -p "  Enable semantic search? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            ENABLE_SEMANTIC_SEARCH="no"
            BUILD_SEMANTIC_DB="no"
            echo ""
            info "Semantic search will not be configured."
            echo "   To enable it later, re-run this script or run:"
            echo "   ~/.local/bin/zotero-mcp update-db"
        fi
    fi

    # PDF indexing pages
    if [[ "$ENABLE_SEMANTIC_SEARCH" == "yes" ]]; then
        echo ""
        echo "  How many pages of each PDF should be indexed for search?"
        echo "  More pages = better search but longer initial build time."
        echo "  By default, this uses a local model — no tokens or usage"
        echo "  limits consumed."
        echo ""
        echo "    • 10 pages  — fast build, covers abstract + introduction"
        echo "    • 20 pages  — moderate, adds some results/discussion"
        echo "    • 50 pages  — thorough, covers most of each paper (recommended)"
        echo ""
        read -p "  Enter number of pages (default: 50): " PDF_INDEX_INPUT
        PDF_INDEX_PAGES="${PDF_INDEX_INPUT:-50}"
        # Validate numeric input
        if ! [[ "$PDF_INDEX_PAGES" =~ ^[0-9]+$ ]]; then
            warn "Invalid input '$PDF_INDEX_PAGES'. Using default: 50"
            PDF_INDEX_PAGES="50"
        fi
    fi

    # Display pages
    echo ""
    echo "  When Claude reads a paper during conversation, how many pages"
    echo "  should it have access to and read? More pages = better"
    echo "  understanding but uses more of your Claude usage allowance"
    echo "  (tokens)."
    echo ""
    echo "    • 10 pages  — conservative, saves usage (recommended)"
    echo "    • 20 pages  — balanced"
    echo "    • 50 pages  — thorough, higher token usage"
    echo ""
    read -p "  Enter number of pages (default: 10): " PDF_DISPLAY_INPUT
    PDF_DISPLAY_PAGES="${PDF_DISPLAY_INPUT:-10}"
    if ! [[ "$PDF_DISPLAY_PAGES" =~ ^[0-9]+$ ]]; then
        warn "Invalid input '$PDF_DISPLAY_PAGES'. Using default: 10"
        PDF_DISPLAY_PAGES="10"
    fi

    # Semantic DB build timing
    if [[ "$ENABLE_SEMANTIC_SEARCH" == "yes" ]]; then
        echo ""
        echo "  Would you like to build the semantic search database now?"
        echo "  This is a one-time process that takes 5-15 minutes."
        echo ""
        echo "  Recommended: Yes"
        read -p "  Build now? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            BUILD_SEMANTIC_DB="no"
            echo ""
            info "You can build it later by re-running this script or:"
            echo "   ~/.local/bin/zotero-mcp update-db --fulltext"
        fi
    fi

fi  # end advanced mode

# --- Prompt for API credentials ---
if [[ "$ACCESS_MODE" == "hybrid" ]] || [[ "$ACCESS_MODE" == "web" ]]; then
    ENABLE_WRITE_SUPPORT="true"

    # Check for existing credentials in Claude Desktop config
    EXISTING_API_KEY=""
    EXISTING_LIBRARY_ID=""
    if [[ -f "$CLAUDE_CONFIG_FILE" ]]; then
        EXISTING_API_KEY=$(python3 -c "
import json
try:
    with open('$CLAUDE_CONFIG_FILE') as f:
        c = json.load(f)
    print(c.get('mcpServers',{}).get('zotero',{}).get('env',{}).get('ZOTERO_API_KEY',''))
except: pass
" 2>/dev/null) || true
        EXISTING_LIBRARY_ID=$(python3 -c "
import json
try:
    with open('$CLAUDE_CONFIG_FILE') as f:
        c = json.load(f)
    print(c.get('mcpServers',{}).get('zotero',{}).get('env',{}).get('ZOTERO_LIBRARY_ID',''))
except: pass
" 2>/dev/null) || true
    fi

    section "Setting up Zotero API Access"

    if [[ -n "$EXISTING_API_KEY" ]] && [[ -n "$EXISTING_LIBRARY_ID" ]]; then
        # Show existing credentials and offer to keep them
        MASKED_KEY="${EXISTING_API_KEY:0:4}***${EXISTING_API_KEY: -4}"
        echo "  Existing credentials found in your config:"
        echo ""
        echo "    API Key:  $MASKED_KEY"
        echo "    User ID:  $EXISTING_LIBRARY_ID"
        echo ""
        echo "  Recommended: Keep existing"
        read -p "  Keep these credentials? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            ZOTERO_API_KEY="$EXISTING_API_KEY"
            ZOTERO_LIBRARY_ID="$EXISTING_LIBRARY_ID"
            success "Using existing API credentials"
            pause 0.3
        else
            echo ""
            echo "  Enter new credentials below."
            EXISTING_API_KEY=""  # Clear so we fall through to the manual entry
        fi
    fi

    # Manual entry (if no existing credentials or user chose to replace)
    if [[ -z "$ZOTERO_API_KEY" ]]; then
        echo ""
        echo "  To enable write operations (adding papers, managing collections,"
        echo "  updating metadata), you'll need a Zotero API key."
        echo ""
        echo "  Note: You'll need to be logged in to Zotero on the web."
        echo "  If you haven't verified your email with Zotero yet, you"
        echo "  may need to do that first."
        echo ""
        echo "  1. Go to this URL:"
        echo ""
        echo "     https://www.zotero.org/settings/keys"
        echo ""
        echo "     (If that link doesn't work, go to zotero.org, log in,"
        echo "      then navigate to Settings > Feeds/API)"
        echo "  2. Click \"Create new private key\""
        echo "  3. Give it a name (e.g., \"Claude MCP\")"
        echo "  4. Under \"Personal Library\", check ALL of these:"
        echo "       ☐ Allow library access"
        echo "       ☐ Allow write access"
        echo "       ☐ Allow notes access"
        echo "  5. Click \"Save Key\" and copy the key shown"
        echo ""
        read -p "  Enter your Zotero API Key (or press Enter to skip): " ZOTERO_API_KEY
        echo ""

        if [[ -n "$ZOTERO_API_KEY" ]]; then
            echo ""
            echo "  Now we need your Zotero User ID."
            echo ""
            echo "  Go back to this URL:"
            echo ""
            echo "     https://www.zotero.org/settings/keys"
            echo ""
            echo "  Your User ID is the number labeled \"Your userID for"
            echo "  use in API calls\" — it's NOT your username."
            echo ""
            read -p "  Enter your Zotero User ID: " ZOTERO_LIBRARY_ID
            echo ""

            if [[ -n "$ZOTERO_LIBRARY_ID" ]]; then
                success "API credentials captured"
                pause 0.3
            else
                warn "No User ID provided. Configuring local-only mode."
                ENABLE_WRITE_SUPPORT=""
                ZOTERO_API_KEY=""
            fi
        fi
    fi

    if [[ -z "$ZOTERO_API_KEY" ]]; then
        warn "Skipping API key setup."
        ENABLE_WRITE_SUPPORT=""
        if [[ "$ACCESS_MODE" == "web" ]]; then
            fail "Web API mode requires an API key. Switching to local-only mode."
            ACCESS_MODE="local"
        fi
        echo ""
        info "The MCP will work in read-only local mode."
        echo "   You can re-run this script later to add write support."
    fi
fi

# ============================================================================
# STEP 3: Install uv
# ============================================================================

echo ""

if command -v uv &>/dev/null; then
    success "uv is already installed ($(uv --version 2>/dev/null || echo 'version unknown'))"
else
    info "Installing uv (Python package manager)..."

    # Step 1: Try curl install
    UV_INSTALLED=false
    if curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null; then
        UV_INSTALLED=true
    fi

    # Step 2: If curl failed and brew is available, try brew
    if [[ "$UV_INSTALLED" == false ]] && command -v brew &>/dev/null; then
        info "Curl install failed. Trying Homebrew..."
        if brew install uv 2>/dev/null; then
            UV_INSTALLED=true
        fi
    fi

    # Step 3: If both failed, show manual instructions and exit
    if [[ "$UV_INSTALLED" == false ]]; then
        echo ""
        fail "Could not install uv automatically."
        echo ""
        echo "   Please try one of these in your Terminal:"
        echo ""
        echo "     Option 1: curl -LsSf https://astral.sh/uv/install.sh | sh"
        echo "     Option 2: brew install uv"
        echo ""
        echo "   Then run this installer script again."
        exit 1
    fi

    if [[ -f "$HOME/.local/bin/env" ]]; then
        source "$HOME/.local/bin/env"
    elif [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi

    if ! command -v uv &>/dev/null; then
        for candidate in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
            if [[ -f "$candidate" && -x "$candidate" ]]; then
                export PATH="$(dirname "$candidate"):$PATH"
                break
            fi
        done
    fi

    if command -v uv &>/dev/null; then
        success "uv installed ($(uv --version))"
    else
        fail "uv installation failed. Try: curl -LsSf https://astral.sh/uv/install.sh | sh"
        exit 1
    fi
fi

# ============================================================================
# STEP 4: Install Zotero MCP Server
# ============================================================================

echo ""
echo "  Note: macOS may ask for permission to access your Downloads"
echo "  or other folders. If you see a popup, click \"Allow\"."
echo ""
info "Please wait while we download and install the server"
info "with all dependencies (may take a minute or two)..."
echo ""

# Remove old pip version if present
if pip3 show zotero-mcp-server &>/dev/null 2>&1; then
    warn "Removing old pip-installed version to avoid conflicts..."
    pip3 uninstall zotero-mcp-server -y 2>/dev/null || true
fi

if [[ "$USE_FORK" == true ]]; then
    INSTALL_PKG="zotero-mcp-server[all] @ git+https://github.com/ehawkin/zotero-mcp@secret"
    info "Installing from Eugene's fork (latest development version)..."
else
    INSTALL_PKG="zotero-mcp-server[all]"
fi

# First attempt
uv tool install --force --reinstall "$INSTALL_PKG" > /dev/null 2>&1 &
spin $! "Installing Zotero MCP server..."
if ! wait $!; then
    # Second attempt: clear cache and retry (show output this time)
    warn "First install attempt failed. Retrying..."
    uv cache clean > /dev/null 2>&1 || true
    echo ""
    if ! uv tool install --force --reinstall "$INSTALL_PKG" 2>&1; then
        echo ""
        fail "Server installation failed."
        echo ""
        echo "   Please try running the following command in your Terminal:"
        echo ""
        echo "     uv tool install --force $INSTALL_PKG"
        echo ""
        echo "   Once that completes, run this installer script again"
        echo "   to finish the setup."
        exit 1
    fi
fi

if [[ "$USE_FORK" == true ]]; then
    success "Zotero MCP server installed (from Eugene's fork)"
else
    success "Zotero MCP server installed"
fi
pause 0.5
# Ensure ~/.local/bin is in PATH (uv tool install puts executables here)
export PATH="$HOME/.local/bin:$PATH"

# Find the executable — check multiple locations
ZOTERO_MCP_PATH=""
for CANDIDATE in \
    "$HOME/.local/bin/zotero-mcp" \
    "$HOME/.local/share/uv/tools/zotero-mcp-server/bin/zotero-mcp" \
    "$(command -v zotero-mcp 2>/dev/null || true)"; do
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" && -x "$CANDIDATE" ]]; then
        # Skip uv cache paths (temporary, not stable)
        if [[ "$CANDIDATE" != *"/.cache/uv/"* ]]; then
            ZOTERO_MCP_PATH="$CANDIDATE"
            break
        fi
    fi
done

if [[ -z "$ZOTERO_MCP_PATH" ]]; then
    # Last resort: search common install locations
    ZOTERO_MCP_PATH=$(find "$HOME/.local" -name "zotero-mcp" -type f -perm +111 2>/dev/null | grep -v "/.cache/" | head -1)
fi

if [[ -z "$ZOTERO_MCP_PATH" ]]; then
    echo ""
    fail "Could not locate the zotero-mcp executable."
    echo ""
    echo "   This usually means uv installed it in an unexpected location."
    echo "   Try running this command to find it:"
    echo "     uv tool list"
    echo ""
    echo "   Or try reinstalling manually:"
    echo "     uv tool install --force zotero-mcp-server[all]"
    echo ""
    echo "   Then re-run this script."
    exit 1
fi

# ============================================================================
# STEP 5: Configure Claude Desktop
# ============================================================================

echo ""

# Build environment variables based on access mode
if [[ "$ACCESS_MODE" == "web" ]]; then
    ENV_DICT="{'ZOTERO_API_KEY': '$ZOTERO_API_KEY', 'ZOTERO_LIBRARY_ID': '$ZOTERO_LIBRARY_ID', 'ZOTERO_LIBRARY_TYPE': 'user'}"
else
    ENV_DICT="{'ZOTERO_LOCAL': 'true'"
    if [[ -n "$ENABLE_WRITE_SUPPORT" ]] && [[ -n "$ZOTERO_API_KEY" ]] && [[ -n "$ZOTERO_LIBRARY_ID" ]]; then
        ENV_DICT="$ENV_DICT, 'ZOTERO_API_KEY': '$ZOTERO_API_KEY', 'ZOTERO_LIBRARY_ID': '$ZOTERO_LIBRARY_ID', 'ZOTERO_LIBRARY_TYPE': 'user'"
    fi
    ENV_DICT="$ENV_DICT}"
fi

if [[ ! -f "$CLAUDE_CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CLAUDE_CONFIG_FILE")"
fi

# Back up existing config with timestamp
if [[ -f "$CLAUDE_CONFIG_FILE" ]]; then
    BACKUP_TIMESTAMP=$(date +%Y-%m-%d_%H%M)
    BACKUP_FILE="${CLAUDE_CONFIG_FILE%.json}_backup_${BACKUP_TIMESTAMP}.json"
    if cp "$CLAUDE_CONFIG_FILE" "$BACKUP_FILE" 2>/dev/null; then
        success "Config backed up to $(basename "$BACKUP_FILE")"
    else
        warn "Could not create config backup (continuing anyway)"
    fi
fi

# Safely merge JSON config
if ! python3 << PYEOF
import json, os

config_path = "$CLAUDE_CONFIG_FILE"
zotero_mcp_path = "$ZOTERO_MCP_PATH"
env_dict = $ENV_DICT

config = {}
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        pass

config.setdefault('mcpServers', {})
config['mcpServers']['zotero'] = {
    'command': zotero_mcp_path,
    'env': env_dict
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF
then
    warn "Could not write Claude config automatically."
    echo ""
    echo "   Please add the following to your Claude Desktop config file:"
    echo "   $CLAUDE_CONFIG_FILE"
    echo ""
    echo "   Add this inside the \"mcpServers\" section:"
    echo ""
    echo "     \"zotero\": {"
    echo "       \"command\": \"$ZOTERO_MCP_PATH\","
    echo "       \"env\": $ENV_DICT"
    echo "     }"
    echo ""
fi

success "Claude Desktop configured for $(echo "$ACCESS_MODE" | sed 's/hybrid/hybrid (read + write)/;s/local/local-only (read)/;s/web/web API/') mode"
pause 0.5
# ============================================================================
# STEP 6: Configure Semantic Search
# ============================================================================

if [[ "$ENABLE_SEMANTIC_SEARCH" == "yes" ]]; then
    echo ""

    SEMANTIC_CONFIG_DIR="$HOME/.config/zotero-mcp"
    SEMANTIC_CONFIG_FILE="$SEMANTIC_CONFIG_DIR/config.json"
    mkdir -p "$SEMANTIC_CONFIG_DIR"

    if ! python3 << PYEOF
import json, os

config_path = "$SEMANTIC_CONFIG_FILE"
pdf_index_pages = int("$PDF_INDEX_PAGES")
pdf_display_pages = int("$PDF_DISPLAY_PAGES")

config = {}
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
    except Exception:
        pass

ss = config.setdefault('semantic_search', {})
uc = ss.setdefault('update_config', {})
uc['auto_update'] = True
uc['update_frequency'] = 'startup'

ext = ss.setdefault('extraction', {})
ext['pdf_max_pages'] = pdf_index_pages
ext['fulltext_display_max_pages'] = pdf_display_pages

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF
    then
        warn "Could not write semantic search config. Default settings will be used."
    fi

    success "Auto-update on startup: enabled"
    success "Full-text indexing: enabled"
    success "PDF indexing limit: $PDF_INDEX_PAGES pages"
    echo ""
    success "Display limit: $PDF_DISPLAY_PAGES pages"
fi

# ============================================================================
# STEP 7: Build Semantic Search Database
# ============================================================================

if [[ "$BUILD_SEMANTIC_DB" == "yes" ]]; then
    echo ""

    # Check if database already exists
    DB_PATH="$HOME/.config/zotero-mcp/chroma_db"
    if [[ -d "$DB_PATH" ]]; then
        echo "  An existing search database was found."
        echo ""
        echo "  Rebuilding will apply your updated settings and index any"
        echo "  new papers, which may improve search quality."
        echo "  This takes 5-15 minutes."
        echo ""
        echo "  Recommended: Yes"
        read -p "  Rebuild now? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            info "Keeping existing database."
            echo "   To rebuild later, re-run this script or run:"
            echo "   $ZOTERO_MCP_PATH update-db --force-rebuild --fulltext"
            BUILD_SEMANTIC_DB="no"
        fi
    fi

    if [[ "$BUILD_SEMANTIC_DB" == "yes" ]]; then
        # Check if Zotero is reachable — retry loop
        while true; do
            ZOTERO_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:23119/api/users/0/items?limit=1" 2>/dev/null || echo "000")
            if [[ "$ZOTERO_HTTP_CODE" == "200" ]]; then
                break  # Zotero is running and API is enabled
            elif [[ "$ZOTERO_HTTP_CODE" == "403" ]]; then
                # Zotero is running but API is disabled
                echo ""
                warn "Zotero is running, but the local API is not enabled."
                echo ""
                echo "   Please enable this setting in Zotero:"
                echo ""
                echo "      Settings > Advanced"
                echo ""
                echo "      ☑ Allow other applications on this computer"
                echo "        to communicate with Zotero"
                echo ""
                echo "   Once enabled, press Enter to try again"
                echo "   or press S to skip the database build."
                echo ""
            else
                # Zotero not running or not reachable
                echo ""
                warn "Cannot connect to Zotero."
                echo ""
                echo "   Please make sure Zotero is running, and that this"
                echo "   setting is enabled:"
                echo ""
                echo "      Settings > Advanced"
                echo ""
                echo "      ☑ Allow other applications on this computer"
                echo "        to communicate with Zotero"
                echo ""
                echo "   Press Enter to try again or S to skip."
                echo ""
            fi

            read -p "   [Enter to retry / S to skip]: " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Ss]$ ]]; then
                info "Skipping database build."
                echo "   Start Zotero with the setting enabled, then run:"
                echo "   $ZOTERO_MCP_PATH update-db --fulltext"
                echo "   Or just open Claude Desktop — it will build automatically."
                BUILD_SEMANTIC_DB="no"
                break
            fi
        done

        if [[ "$BUILD_SEMANTIC_DB" == "yes" ]]; then
            echo ""
            info "Building semantic search database with full-text indexing..."
            info "This indexes the content of your papers for better search."
            echo ""
            info "You can start using the MCP in Claude Desktop while this runs."
            info "All tools work immediately — semantic search results will"
            info "improve once the build completes."
            echo ""

            if ZOTERO_LOCAL=true "$ZOTERO_MCP_PATH" update-db --fulltext 2>&1; then
                echo ""
                success "Semantic search database built"
                pause 0.5
            else
                echo ""
                warn "Database build had issues."
                if [[ -d "$DB_PATH" ]]; then
                    echo "   A partial database may exist. To rebuild from scratch:"
                    echo "   $ZOTERO_MCP_PATH update-db --fulltext --force-rebuild"
                else
                    echo "   To try again later:"
                    echo "   $ZOTERO_MCP_PATH update-db --fulltext"
                fi
            fi
        fi
    fi
fi

# ============================================================================
# STEP 8: Complete!
pause 1
# ============================================================================

echo ""
echo ""
echo -e "  ${GREEN}✓ Installation Complete!${NC}"
echo ""
echo "  To start using Zotero MCP:"
echo ""
echo "  1. Make sure Zotero is running"
echo "  2. Open Claude Desktop (restart if already open)"
echo "  3. Start chatting! Try:"
echo "     \"What papers are in my library about [topic]?\""
echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${RED}${BOLD}IMPORTANT:${NC} In Zotero, go to:"
echo "    Settings > Advanced"
echo -e "  and make sure this is ${BOLD}CHECKED${NC}:"
echo -e "    ${BLUE}☑ Allow other applications on this computer${NC}"
echo -e "    ${BLUE}  to communicate with Zotero${NC}"
echo -e "  ${RED}${BOLD}Without this, the MCP cannot connect!${NC}"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Show setup summary
if [[ -n "$ENABLE_WRITE_SUPPORT" ]] && [[ -n "$ZOTERO_API_KEY" ]]; then
    echo -e "  Your setup: ${GREEN}Hybrid mode (read + write)${NC}"
    echo ""
    echo "  Claude can search, add papers by DOI, manage collections,"
    echo "  tag items, create notes, find duplicates, and more."
elif [[ "$ACCESS_MODE" == "web" ]]; then
    echo -e "  Your setup: ${YELLOW}Web API mode${NC}"
    echo "  Re-run this script to switch to hybrid mode."
else
    echo -e "  Your setup: ${YELLOW}Local-only mode (read access)${NC}"
    echo "  Re-run this script to add write support."
fi

if [[ "$ENABLE_SEMANTIC_SEARCH" == "no" ]]; then
    echo ""
    echo "  Semantic search: Not configured."
    echo "  To enable, re-run this script or run:"
    echo "  $ZOTERO_MCP_PATH update-db --fulltext"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  If you have any issues, run the diagnostic tool:"
echo "    bash install-zotero-mcp.sh --diagnose"
echo ""
