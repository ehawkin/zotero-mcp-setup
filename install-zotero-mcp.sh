#!/bin/bash

# =============================================================================
# Zotero MCP Server Installer for macOS
# Connects your Zotero research library to Claude and other AI assistants
#
# Uses 'uv' (the recommended installer) — no Python or pip required.
# If uv is not installed, the script installs it automatically.
#
# Usage: bash install-zotero-mcp.sh
# Do NOT run with sudo.
# Press Ctrl+C at any time to quit.
# =============================================================================

set -e

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

echo -e "${CYAN}━━ Checking Prerequisites ━━${NC}"
echo ""

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
    echo ""
    warn "Git is not installed. It's needed to download the server."
    echo ""
    echo "   We'll open the macOS developer tools installer for you."
    echo "   A dialog box will appear — click \"Install\" and wait for"
    echo "   it to finish (this downloads about 1.5 GB and may take"
    echo "   5-10 minutes depending on your internet speed)."
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

# ============================================================================
# STEP 2: Installation Mode
# ============================================================================

echo ""
echo -e "${CYAN}━━ Installation Mode ━━${NC}"
echo ""

# Defaults
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
    read -p "  Enter choice (1/2): " SETUP_MODE
    echo ""
fi

# --- Advanced mode options ---
if [[ "$SETUP_MODE" == "2" ]]; then

    # Access mode
    echo -e "${CYAN}━━ Access Mode ━━${NC}"
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
    read -p "  Enter choice (1/2/3): " ACCESS_CHOICE
    echo ""

    case "$ACCESS_CHOICE" in
        2) ACCESS_MODE="local" ;;
        3) ACCESS_MODE="web"; ENABLE_SEMANTIC_SEARCH="no"; BUILD_SEMANTIC_DB="no" ;;
        *) ACCESS_MODE="hybrid" ;;
    esac

    # Semantic search
    if [[ "$ACCESS_MODE" != "web" ]]; then
        echo -e "${CYAN}━━ Semantic Search Settings ━━${NC}"
        echo ""
        echo "  Semantic search lets you find papers by meaning, not just keywords."
        echo "  For example: \"papers about the relationship between sleep and memory\""
        echo ""
        echo "  By default, it uses a small local AI model that runs on your"
        echo "  computer — no tokens or usage limits are consumed."
        echo ""
        read -p "  Enable semantic search? (Y/n) ← recommended  " -n 1 -r
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
        echo -e "${CYAN}━━ PDF Indexing for Semantic Search ━━${NC}"
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
    fi

    # Display pages
    echo ""
    echo -e "${CYAN}━━ Claude Reading Limit ━━${NC}"
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

    # Semantic DB build timing
    if [[ "$ENABLE_SEMANTIC_SEARCH" == "yes" ]]; then
        echo ""
        echo "  Would you like to build the semantic search database now?"
        echo "  This is a one-time process that takes 5-15 minutes."
        echo ""
        read -p "  Build now? (Y/n) ← recommended  " -n 1 -r
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

    echo ""
    echo -e "${CYAN}━━ Setting up Zotero API Access ━━${NC}"
    echo ""
    echo "  To enable write operations (adding papers, managing collections,"
    echo "  updating metadata), you'll need a Zotero API key."
    echo ""
    echo "  1. Go to: https://zotero.org/settings/keys"
    echo "  2. Click \"Create new private key\""
    echo "  3. Give it a name (e.g., \"Claude MCP\")"
    echo "  4. Under \"Personal Library\", check:"
    echo "       ☐ Allow library access"
    echo "       ☐ Allow write access"
    echo "  5. Click \"Save Key\" and copy the key shown"
    echo ""
    read -p "  Enter your Zotero API Key (or press Enter to skip): " ZOTERO_API_KEY
    echo ""

    if [[ -n "$ZOTERO_API_KEY" ]]; then
        echo "  Your User ID is labeled \"Your userID for use in API calls\""
        echo "  on the same page — it's the number, not your username."
        echo ""
        read -p "  Enter your Zotero User ID: " ZOTERO_LIBRARY_ID
        echo ""

        if [[ -n "$ZOTERO_LIBRARY_ID" ]]; then
            success "API credentials captured"
        else
            warn "No User ID provided. Configuring local-only mode."
            ENABLE_WRITE_SUPPORT=""
            ZOTERO_API_KEY=""
        fi
    else
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
echo -e "${CYAN}━━ Installing Dependencies ━━${NC}"
echo ""

if command -v uv &>/dev/null; then
    success "uv is already installed ($(uv --version))"
else
    info "Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh

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
echo -e "${CYAN}━━ Installing Zotero MCP Server ━━${NC}"
echo ""
info "Please wait while we download and install the server"
info "with all dependencies (may take a minute or two)..."
echo ""

# Remove old pip version if present
if pip3 show zotero-mcp-server &>/dev/null 2>&1; then
    warn "Removing old pip-installed version to avoid conflicts..."
    pip3 uninstall zotero-mcp-server -y 2>/dev/null || true
fi

INSTALL_PKG="zotero-mcp-server[all]"

if uv tool list 2>/dev/null | grep -q "zotero-mcp-server"; then
    uv tool install --force --reinstall "$INSTALL_PKG" 2>&1 | tail -1
else
    uv tool install "$INSTALL_PKG" 2>&1 | tail -1
fi
success "Zotero MCP server installed"

# Find the executable
ZOTERO_MCP_PATH=""
CANDIDATE="$HOME/.local/bin/zotero-mcp"
if [[ -f "$CANDIDATE" && -x "$CANDIDATE" ]]; then
    ZOTERO_MCP_PATH="$CANDIDATE"
fi

if [[ -z "$ZOTERO_MCP_PATH" ]]; then
    FOUND_PATH="$(command -v zotero-mcp 2>/dev/null || true)"
    if [[ -n "$FOUND_PATH" && "$FOUND_PATH" != *"/.cache/uv/"* ]]; then
        ZOTERO_MCP_PATH="$FOUND_PATH"
    fi
fi

if [[ -z "$ZOTERO_MCP_PATH" ]]; then
    fail "Could not locate zotero-mcp executable."
    exit 1
fi

# ============================================================================
# STEP 5: Configure Claude Desktop
# ============================================================================

echo ""
echo -e "${CYAN}━━ Configuring Claude Desktop ━━${NC}"
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
    cp "$CLAUDE_CONFIG_FILE" "$BACKUP_FILE"
    success "Config backed up to $(basename "$BACKUP_FILE")"
fi

# Safely merge JSON config
python3 << PYEOF
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

success "Claude Desktop configured for $(echo "$ACCESS_MODE" | sed 's/hybrid/hybrid (read + write)/;s/local/local-only (read)/;s/web/web API/') mode"

# ============================================================================
# STEP 6: Configure Semantic Search
# ============================================================================

if [[ "$ENABLE_SEMANTIC_SEARCH" == "yes" ]]; then
    echo ""
    echo -e "${CYAN}━━ Configuring Semantic Search ━━${NC}"
    echo ""

    SEMANTIC_CONFIG_DIR="$HOME/.config/zotero-mcp"
    SEMANTIC_CONFIG_FILE="$SEMANTIC_CONFIG_DIR/config.json"
    mkdir -p "$SEMANTIC_CONFIG_DIR"

    python3 << PYEOF
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

    success "Auto-update on startup: enabled"
    success "Full-text indexing: enabled"
    success "PDF indexing limit: $PDF_INDEX_PAGES pages"
    echo ""
    echo -e "${CYAN}━━ Claude Reading Limit ━━${NC}"
    echo ""
    success "Display limit: $PDF_DISPLAY_PAGES pages"
fi

# ============================================================================
# STEP 7: Build Semantic Search Database
# ============================================================================

if [[ "$BUILD_SEMANTIC_DB" == "yes" ]]; then
    echo ""
    echo -e "${CYAN}━━ Semantic Search Database ━━${NC}"
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
        read -p "  Rebuild now? (Y/n) ← recommended  " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            info "Keeping existing database."
            echo "   To rebuild later, re-run this script or run:"
            echo "   $ZOTERO_MCP_PATH update-db --force-rebuild --fulltext"
            BUILD_SEMANTIC_DB="no"
        fi
    fi

    if [[ "$BUILD_SEMANTIC_DB" == "yes" ]]; then
        # Check if Zotero is reachable before building
        if ! curl -s --max-time 2 http://127.0.0.1:23119/api/users/0/items?limit=1 >/dev/null 2>&1; then
            echo ""
            warn "Cannot connect to Zotero."
            echo ""
            echo "   Please make sure:"
            echo "   1. Zotero is running"
            echo "   2. This setting is ENABLED in Zotero:"
            echo ""
            echo "      Mac:     Settings > General"
            echo "      Windows: Edit > Settings > General"
            echo ""
            echo "      ☑ Allow other applications on this computer"
            echo "        to communicate with Zotero"
            echo ""
            echo "   Once you've checked both, press Enter to try again"
            echo "   or press S to skip the database build."
            echo ""
            read -p "   [Enter to retry / S to skip]: " -r
            if [[ $REPLY =~ ^[Ss]$ ]]; then
                info "Skipping database build."
                echo "   Start Zotero with the setting enabled, then run:"
                echo "   $ZOTERO_MCP_PATH update-db --fulltext"
                echo "   Or just open Claude Desktop — it will build automatically."
                BUILD_SEMANTIC_DB="no"
            fi
        fi

        if [[ "$BUILD_SEMANTIC_DB" == "yes" ]] && curl -s --max-time 2 http://127.0.0.1:23119/api/users/0/items?limit=1 >/dev/null 2>&1; then
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
            else
                echo ""
                warn "Database build had issues. You can try again later with:"
                echo "   $ZOTERO_MCP_PATH update-db --fulltext --force-rebuild"
            fi
        else
            warn "Still cannot connect to Zotero — skipping database build."
            echo "   Make sure Zotero is running with the 'Allow other applications'"
            echo "   setting enabled, then run: $ZOTERO_MCP_PATH update-db --fulltext"
            echo "   Or just open Claude Desktop — it will build automatically."
        fi
    fi
fi

# ============================================================================
# STEP 8: Complete!
# ============================================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║${GREEN}              ✓ Installation Complete!                    ${NC}${BOLD}║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}                                                          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  To start using Zotero MCP:                              ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                                                          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  1. Make sure Zotero is running                          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  2. Open Claude Desktop (restart if already open)        ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  3. Start chatting! Try:                                 ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}     \"What papers are in my library about [topic]?\"       ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                                                          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${NC}    ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>> ${BOLD}IMPORTANT: In Zotero, go to:${NC}                    ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>>   Settings > General${NC}                            ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>> ${BOLD}and make sure this is CHECKED:${NC}                  ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>>   ☑ Allow other applications on this computer${NC} ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>>     to communicate with Zotero${NC}                  ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>> ${BOLD}Without this, the MCP cannot connect!${NC}           ${RED}<<<${NC}  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${RED}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${NC}    ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                                                          ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show setup summary
if [[ -n "$ENABLE_WRITE_SUPPORT" ]] && [[ -n "$ZOTERO_API_KEY" ]]; then
    echo "  Your setup: ${GREEN}Hybrid mode (read + write)${NC}"
    echo ""
    echo "  Claude can search, add papers by DOI, manage collections,"
    echo "  tag items, create notes, find duplicates, and more."
elif [[ "$ACCESS_MODE" == "web" ]]; then
    echo "  Your setup: ${YELLOW}Web API mode${NC}"
    echo "  Re-run this script to switch to hybrid mode."
else
    echo "  Your setup: ${YELLOW}Local-only mode (read access)${NC}"
    echo "  Re-run this script to add write support."
fi

if [[ "$ENABLE_SEMANTIC_SEARCH" == "no" ]]; then
    echo ""
    echo "  Semantic search: Not configured."
    echo "  To enable, re-run this script or run:"
    echo "  $ZOTERO_MCP_PATH update-db --fulltext"
fi

echo ""
