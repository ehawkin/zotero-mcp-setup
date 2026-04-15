# =============================================================================
# Zotero MCP Server Installer for Windows
# Connects your Zotero research library to Claude and other AI assistants
#
# Uses 'uv' (the recommended installer) - no Python or pip required.
# If uv is not installed, the script installs it automatically.
#
# Usage: Right-click > Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File install-zotero-mcp.ps1
#   powershell -ExecutionPolicy Bypass -File install-zotero-mcp.ps1 -eugene
# Press Ctrl+C at any time to quit.
#
# Optional switches (all have sensible defaults; running with no switches
# reproduces the classic behavior: local embedding, full-text indexing,
# 50 index pages / 10 display pages):
#
#   -Embedding <local|openai|gemini>
#       Choose the embedding backend for semantic search. Default: local
#       (a small on-device model, no API key required). "openai" and
#       "gemini" send paper content to the respective cloud provider.
#
#   -OpenAIVariant <small|large>
#       With -Embedding openai, pick text-embedding-3-small (default) or
#       text-embedding-3-large. Ignored otherwise.
#
#   -OpenAIKey <string>
#       OpenAI API key. Written to the Claude Desktop config so indexing
#       and query-time embeddings can authenticate. Only used with
#       -Embedding openai. If omitted, you'll need to set OPENAI_API_KEY
#       in your environment before the first index run.
#
#   -GeminiKey <string>
#       Google Gemini API key. Only used with -Embedding gemini.
#
#   -IndexDepth <metadata|full>
#       Default: full. Controls whether 'update-db' is passed --fulltext.
#       Use "metadata" for a much faster index of titles/abstracts only.
#
#   -PagesIndex <int>
#       Max PDF pages to index per paper. Default: 50. Written to
#       semantic_search.extraction.pdf_max_pages.
#
#   -PagesDisplay <int>
#       Max PDF pages Claude can read during a conversation. Default: 10.
#       Written to semantic_search.extraction.fulltext_display_max_pages.
#
#   -AnnotationLimit <int>
#       Sets ZOTERO_MCP_ANNOTATION_LIMIT in the Claude config. Omit to
#       leave unset (server default applies).
#
# Example (OpenAI small variant, metadata-only index):
#   powershell -ExecutionPolicy Bypass -File install-zotero-mcp.ps1 `
#       -Embedding openai -OpenAIKey sk-... -IndexDepth metadata
# =============================================================================

param(
    [switch]$eugene,
    [switch]$diagnose,
    [ValidateSet("local", "openai", "gemini")]
    [string]$Embedding = "local",
    [ValidateSet("small", "large")]
    [string]$OpenAIVariant = "small",
    [string]$OpenAIKey = "",
    [string]$GeminiKey = "",
    [ValidateSet("metadata", "full")]
    [string]$IndexDepth = "full",
    [int]$PagesIndex = 50,
    [int]$PagesDisplay = 10,
    [int]$AnnotationLimit = -1
)

$ErrorActionPreference = "Continue"

# --diagnose: run diagnostics only, no install
if ($diagnose) {
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $py) {
        Write-Host "Error: Python 3 is required to run diagnostics." -ForegroundColor Red
        exit 1
    }
    $diagScript = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.py'
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/zotero-mcp-diagnostic.py" -OutFile $diagScript -UseBasicParsing
    } catch {
        Write-Host "Error: Could not download diagnostic script. Check your internet connection." -ForegroundColor Red
        exit 1
    }
    & $py.Source $diagScript
    Remove-Item $diagScript -ErrorAction SilentlyContinue
    exit $LASTEXITCODE
}

# --- PS 5.1 compatible helper functions ---
function Info($msg)    { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Success($msg) { Write-Host "  $([char]0x2713) $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $([char]0x26A0) $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  $([char]0x2717) $msg" -ForegroundColor Red }

# Helper: Convert PSCustomObject to hashtable (PS 5.1 compatibility)
function ConvertTo-Hashtable($obj) {
    if ($null -eq $obj) { return @{} }
    if ($obj -is [hashtable]) { return $obj }
    $ht = @{}
    $obj.PSObject.Properties | ForEach-Object {
        $val = $_.Value
        if ($val -is [System.Management.Automation.PSCustomObject]) {
            $val = ConvertTo-Hashtable $val
        }
        $ht[$_.Name] = $val
    }
    return $ht
}

# Helper: Write JSON without BOM (PS 5.1 writes UTF-8 with BOM by default)
function Write-JsonNoBom($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

# UX helpers
function Pause-Script($seconds) { Start-Sleep -Milliseconds ([int]($seconds * 1000)) }
function Section($title) {
    Write-Host ""
    Write-Host "-- $title --" -ForegroundColor Cyan
    Write-Host ""
    Pause-Script 0.3
}

# Lightweight separator between consecutive questions inside a section,
# so the user's eye sees each question as a distinct unit instead of a
# wall of running text.
function Qsep {
    Write-Host ""
    Write-Host "  - - - - - - - - - - - - - - -" -ForegroundColor Cyan
    Write-Host ""
}

Write-Host ""
Write-Host "+==========================================================+" -ForegroundColor White
Write-Host "|          Zotero MCP Server - Installation Script          |" -ForegroundColor White
Write-Host "|                                                           |" -ForegroundColor White
Write-Host "|  This script installs the Zotero MCP server, which       |" -ForegroundColor White
Write-Host "|  connects your Zotero library to Claude and other AI     |" -ForegroundColor White
Write-Host "|  assistants.                                             |" -ForegroundColor White
Write-Host "+==========================================================+" -ForegroundColor White
Write-Host ""

# ============================================================================
# STEP 1: Prerequisites
# ============================================================================

Section "Checking Prerequisites"

# --- Check for Zotero ---
$ZoteroFound = $false
$pf86 = ${env:ProgramFiles(x86)}
$ZoteroPaths = @(
    "$env:ProgramFiles\Zotero\zotero.exe",
    "$env:LOCALAPPDATA\Zotero\zotero.exe"
)
if ($pf86) { $ZoteroPaths += "$pf86\Zotero\zotero.exe" }

foreach ($p in $ZoteroPaths) {
    if (Test-Path $p) { $ZoteroFound = $true; break }
}

if ($ZoteroFound) {
    Success "Zotero desktop app found"
} else {
    Write-Host ""
    Warn "Zotero was not detected on this computer."
    Write-Host ""
    Write-Host "   For the full experience, the MCP server requires Zotero 8."
    Write-Host "   Download it from: https://www.zotero.org/download"
    Write-Host ""
    Write-Host "   If you continue without Zotero, the server will be installed"
    Write-Host "   in Web API-only mode. This provides basic search and library"
    Write-Host "   management but does NOT include:"
    Write-Host "     - Semantic search (find papers by meaning)"
    Write-Host "     - PDF reading, annotation, and outline extraction"
    Write-Host "     - Full-text paper access"
    Write-Host "     - RSS feed access"
    Write-Host ""
    Write-Host "   Install Zotero first, then press Y to continue - or re-run"
    Write-Host "   this script when you're ready."
    Write-Host ""
    $reply = Read-Host "   Continue with Web API-only mode? (y/N)  [Ctrl+C to quit]"
    if ($reply -notmatch "^[Yy]") {
        Info "Install Zotero first, then re-run this script."
        exit 0
    }
}

# --- Check for Claude Desktop ---
$ClaudeConfigDir = "$env:APPDATA\Claude"
$ClaudeConfigFile = "$ClaudeConfigDir\claude_desktop_config.json"

if (Test-Path $ClaudeConfigDir) {
    Success "Claude Desktop found"
} else {
    Write-Host ""
    Warn "Claude Desktop was not found."
    Write-Host ""
    Write-Host "   Download it from: https://claude.ai/download"
    Write-Host ""
    Write-Host "   After installing, press Y to continue - or re-run"
    Write-Host "   this script when you're ready."
    Write-Host ""
    $reply = Read-Host "   Continue? (y/N)  [Ctrl+C to quit]"
    if ($reply -notmatch "^[Yy]") {
        Info "Install Claude Desktop, then re-run this script."
        exit 0
    }
    New-Item -ItemType Directory -Path $ClaudeConfigDir -Force | Out-Null
}

# --- Check for Git ---
if (Get-Command git -ErrorAction SilentlyContinue) {
    Success "Git is available"
} else {
    Warn "Git is not installed. It's needed to download the server."
    Write-Host ""
    Write-Host "   Please install Git using one of these methods:"
    Write-Host ""
    Write-Host "   Option 1 (if you have winget):"
    Write-Host "     winget install Git.Git"
    Write-Host ""
    Write-Host "   Option 2 (download installer):"
    Write-Host "     https://git-scm.com/download/win"
    Write-Host ""
    Write-Host "   After installing, close and reopen PowerShell,"
    Write-Host "   then re-run this script."
    Write-Host ""
    Fail "Git is required to continue."
    exit 1
}

# ============================================================================
# STEP 2: Installation Mode
# ============================================================================

Write-Host ""

# Defaults
$SetupMode = "1"
$ApiKey = ""
$LibraryId = ""
$EnableWrite = $false
$AccessMode = "hybrid"
$BuildDb = $true
$EnableSemantic = $true
$PdfIndexPages = $PagesIndex
$PdfDisplayPages = $PagesDisplay
# Interactive annotation prompt still works; CLI override takes precedence
if ($AnnotationLimit -ge 0) {
    $AnnotationLimitValue = $AnnotationLimit
} else {
    $AnnotationLimitValue = $null
}

# Normalise embedding choices from CLI flags
$EmbeddingModel = $Embedding   # local | openai | gemini
$EmbeddingVariant = $OpenAIVariant  # small | large (only meaningful for openai)
$FullTextIndex = ($IndexDepth -eq "full")

# Warn early if the user asked for a cloud embedding but didn't supply a key
if ($EmbeddingModel -eq "openai" -and -not $OpenAIKey) {
    Warn "No -OpenAIKey supplied. You'll need to set OPENAI_API_KEY in your environment before indexing runs."
}
if ($EmbeddingModel -eq "gemini" -and -not $GeminiKey) {
    Warn "No -GeminiKey supplied. You'll need to set GEMINI_API_KEY in your environment before indexing runs."
}

# If Zotero not found, force web API mode
if (-not $ZoteroFound) {
    Info "Zotero not installed - configuring Web API-only mode."
    $AccessMode = "web"
    $BuildDb = $false
    $EnableSemantic = $false
    $EnableWrite = $true
} else {
    Write-Host "  How would you like to configure the installation?"
    Write-Host ""
    Write-Host "    1) Default (recommended)"
    Write-Host "       Hybrid mode: fast local reads + web API for writes"
    Write-Host "       Semantic search enabled with standard settings"
    Write-Host ""
    Write-Host "    2) Advanced"
    Write-Host "       Choose your access mode and customize settings"
    Write-Host ""
    $SetupMode = Read-Host "  Enter choice (1/2)"
}

# --- Advanced mode options ---
if ($SetupMode -eq "2") {

    Section "Access Mode"
    Write-Host "  How should the MCP connect to Zotero?"
    Write-Host ""
    Write-Host "    1) Hybrid (recommended)"
    Write-Host "       Reads from local Zotero (fast), writes via web API"
    Write-Host "       Requires: Zotero running + API key"
    Write-Host ""
    Write-Host "    2) Local only"
    Write-Host "       Reads from local Zotero, no write operations"
    Write-Host "       Requires: Zotero running"
    Write-Host ""
    Write-Host "    3) Web API only"
    Write-Host "       Everything through Zotero's cloud API"
    Write-Host "       Works without Zotero running, but slower and limited:"
    Write-Host "       no semantic search, PDF features, or full-text access"
    Write-Host ""
    $accessChoice = Read-Host "  Enter choice (1/2/3)"

    switch ($accessChoice) {
        "2" { $AccessMode = "local" }
        "3" { $AccessMode = "web"; $EnableSemantic = $false; $BuildDb = $false }
        default { $AccessMode = "hybrid" }
    }

    # Semantic search
    if ($AccessMode -ne "web") {
        Section "Semantic Search Settings"
        Write-Host "  Semantic search lets you find papers by meaning, not just keywords."
        Write-Host "  For example: 'papers about the relationship between sleep and memory'"
        Write-Host ""
        Write-Host "  By default, it uses a small local AI model that runs on your"
        Write-Host "  computer - no tokens or usage limits are consumed."
        Write-Host ""
        Write-Host "  Recommended: Yes"
        $semReply = Read-Host "  Enable semantic search? (Y/n)"
        if ($semReply -match "^[Nn]") {
            $EnableSemantic = $false
            $BuildDb = $false
            Info "Semantic search will not be configured."
            Write-Host "   To enable it later, re-run this script."
        }
    }

    # Embedding model
    if ($EnableSemantic -and -not $PSBoundParameters.ContainsKey('Embedding')) {
        Qsep
        Write-Host "  Which embedding model should index your library?"
        Write-Host ""
        Write-Host "    1) Local - free  (recommended)"
        Write-Host "       Runs on your computer with a small AI model."
        Write-Host "       No account, no API key, no cost."
        Write-Host ""
        Write-Host "    2) OpenAI - pay per use"
        Write-Host "       Higher-quality embeddings. Requires an OpenAI API"
        Write-Host "       account (separate from ChatGPT). Bills per token."
        Write-Host ""
        Write-Host "    3) Gemini - generous free tier"
        Write-Host "       Google's embedding model. The free tier covers most"
        Write-Host "       typical libraries. Requires a Gemini API key."
        Write-Host ""
        $embedChoice = Read-Host "  Enter choice 1, 2, or 3 (default: 1)"
        switch ($embedChoice) {
            "2" { $EmbeddingModel = "openai" }
            "3" { $EmbeddingModel = "gemini" }
            default { $EmbeddingModel = "local" }
        }
    }

    # OpenAI variant (small vs large)
    if ($EnableSemantic -and $EmbeddingModel -eq "openai" -and -not $PSBoundParameters.ContainsKey('OpenAIVariant')) {
        Qsep
        Write-Host "  Which OpenAI embedding model?"
        Write-Host ""
        Write-Host "    1) text-embedding-3-small  (default, cheaper)"
        Write-Host "       Good quality. ~`$0.60 per 1,000 papers (full text, 50 pages)."
        Write-Host ""
        Write-Host "    2) text-embedding-3-large"
        Write-Host "       Best quality. ~6.5x the cost: ~`$3.90 per 1,000 papers."
        Write-Host ""
        $oaiChoice = Read-Host "  Enter choice 1 or 2 (default: 1)"
        switch ($oaiChoice) {
            "2" { $EmbeddingVariant = "large" }
            default { $EmbeddingVariant = "small" }
        }
    }

    # OpenAI API key
    if ($EnableSemantic -and $EmbeddingModel -eq "openai" -and -not $OpenAIKey) {
        Qsep
        Write-Host "  OpenAI API key (starts with sk-)."
        Write-Host "  Get one at https://platform.openai.com/api-keys"
        Write-Host "  (separate from ChatGPT subscription)."
        Write-Host ""
        Write-Host "  Press Enter to skip - we'll fall back to the free local"
        Write-Host "  embedding model instead. You can switch to OpenAI later by"
        Write-Host "  re-running this script."
        Write-Host ""
        $OpenAIKey = Read-Host "  Paste API key (or Enter to skip)"
        if (-not $OpenAIKey) {
            Write-Host ""
            Info "No OpenAI key entered - falling back to the free local embedding model."
            $EmbeddingModel = "local"
            $EmbeddingVariant = ""   # variant choice no longer relevant
        }
    }

    # Gemini API key
    if ($EnableSemantic -and $EmbeddingModel -eq "gemini" -and -not $GeminiKey) {
        Qsep
        Write-Host "  Gemini API key (starts with AIza)."
        Write-Host "  Get one at https://aistudio.google.com/apikey"
        Write-Host ""
        Write-Host "  Press Enter to skip - we'll fall back to the free local"
        Write-Host "  embedding model instead. You can switch to Gemini later by"
        Write-Host "  re-running this script."
        Write-Host ""
        $GeminiKey = Read-Host "  Paste API key (or Enter to skip)"
        if (-not $GeminiKey) {
            Write-Host ""
            Info "No Gemini key entered - falling back to the free local embedding model."
            $EmbeddingModel = "local"
        }
    }

    # Index depth (metadata only vs full text)
    if ($EnableSemantic -and -not $PSBoundParameters.ContainsKey('IndexDepth')) {
        Qsep
        Write-Host "  What should be indexed?"
        Write-Host ""
        Write-Host "    1) Full text  (recommended)"
        Write-Host "       Indexes PDF body text up to the page limit below."
        Write-Host "       Claude can find papers by any phrase or concept."
        Write-Host ""
        Write-Host "    2) Metadata only"
        Write-Host "       Titles, authors, abstracts, tags. Fastest to build,"
        Write-Host "       cheapest on paid models, but no PDF-text search."
        Write-Host ""
        $depthChoice = Read-Host "  Enter choice 1 or 2 (default: 1)"
        switch ($depthChoice) {
            "2" { $FullTextIndex = $false }
            default { $FullTextIndex = $true }
        }
    }

    # PDF indexing pages -- only relevant when full-text indexing
    if ($EnableSemantic -and $FullTextIndex) {
        Qsep
        Write-Host "  How many pages of each PDF should be indexed for search?"
        Write-Host "  More pages = better search but longer initial build time."
        Write-Host ""
        Write-Host "    10 pages  - fast build, covers abstract + introduction"
        Write-Host "    20 pages  - moderate, adds some results/discussion"
        Write-Host "    50 pages  - thorough, covers most of each paper (recommended)"
        Write-Host ""
        $indexInput = Read-Host "  Enter number of pages (default: 50)"
        if ($indexInput) {
            if ($indexInput -match '^\d+$') {
                $PdfIndexPages = [int]$indexInput
            } else {
                Warn "Invalid input '$indexInput'. Using default: 50"
            }
        }
    }

    # Display pages
    Qsep
    Write-Host "  When Claude reads a paper during conversation, how many pages"
    Write-Host "  should it have access to and read? More pages = better"
    Write-Host "  understanding but uses more of your Claude usage allowance"
    Write-Host "  (tokens)."
    Write-Host ""
    Write-Host "    10 pages  - conservative, saves usage (recommended)"
    Write-Host "    20 pages  - balanced"
    Write-Host "    50 pages  - thorough, higher token usage"
    Write-Host ""
    $displayInput = Read-Host "  Enter number of pages (default: 10)"
    if ($displayInput) {
        if ($displayInput -match '^\d+$') {
            $PdfDisplayPages = [int]$displayInput
        } else {
            Warn "Invalid input '$displayInput'. Using default: 10"
        }
    }

    # Annotation limit (currently only respected by Eugene's fork; once
    # upstream merges, it'll apply to everyone -- keep the question gated
    # for now so default-fork users aren't asked about a setting that
    # has no effect for them).
    if ($eugene) {
        Qsep
        Write-Host "  Maximum annotations returned per query."
        Write-Host "  Controls how many annotations Claude can retrieve at once."
        Write-Host "  Higher values = more context but uses more of the conversation window."
        Write-Host ""
        Write-Host "    Range: 1-1000  |  Default: 300"
        Write-Host ""
        # CLI override takes precedence; skip the prompt if -AnnotationLimit was supplied
        if ($null -ne $AnnotationLimitValue) {
            Info "Using annotation limit from -AnnotationLimit: $AnnotationLimitValue"
        } else {
            $annoInput = Read-Host "  Enter annotation limit (default: 300)"
            if ($annoInput) {
                if ($annoInput -match '^\d+$' -and [int]$annoInput -ge 1 -and [int]$annoInput -le 1000) {
                    if ([int]$annoInput -ne 300) {
                        $AnnotationLimitValue = [int]$annoInput
                    }
                } else {
                    Warn "Invalid input '$annoInput'. Using default: 300"
                }
            }
        }
    }

    # Build timing
    if ($EnableSemantic) {
        Qsep
        Write-Host "  Would you like to build the semantic search database now?"
        Write-Host "  This is a one-time process that takes 5-15 minutes."
        Write-Host ""
        Write-Host "  Recommended: Yes"
        $buildReply = Read-Host "  Build now? (Y/n)"
        if ($buildReply -match "^[Nn]") {
            $BuildDb = $false
            Info "You can build it later by re-running this script."
        }
    }
}

# --- API credentials ---
if ($AccessMode -eq "hybrid" -or $AccessMode -eq "web") {
    $EnableWrite = $true

    # Check for existing credentials in Claude Desktop config
    $ExistingApiKey = ""
    $ExistingLibraryId = ""
    if (Test-Path $ClaudeConfigFile) {
        try {
            $existingConfig = Get-Content $ClaudeConfigFile -Raw | ConvertFrom-Json
            $ExistingApiKey = $existingConfig.mcpServers.zotero.env.ZOTERO_API_KEY
            $ExistingLibraryId = $existingConfig.mcpServers.zotero.env.ZOTERO_LIBRARY_ID
        } catch {
            # Config unreadable or missing credentials — will fall through to manual entry
        }
    }

    Section "Setting up Zotero API Access"

    if ($ExistingApiKey -and $ExistingLibraryId) {
        if ($ExistingApiKey.Length -ge 8) {
            $maskedKey = $ExistingApiKey.Substring(0,4) + "***" + $ExistingApiKey.Substring($ExistingApiKey.Length - 4)
        } else {
            $maskedKey = "***"
        }
        Write-Host "  Existing credentials found in your config:"
        Write-Host ""
        Write-Host "    API Key:  $maskedKey"
        Write-Host "    User ID:  $ExistingLibraryId"
        Write-Host ""
        Write-Host "  Recommended: Keep existing"
        $keepReply = Read-Host "  Keep these credentials? (Y/n)"
        if ($keepReply -notmatch "^[Nn]") {
            $ApiKey = $ExistingApiKey
            $LibraryId = $ExistingLibraryId
            Success "Using existing API credentials"
            Pause-Script 0.3
        } else {
            Write-Host ""
            Write-Host "  Enter new credentials below."
            $ExistingApiKey = ""
        }
    }

    if (-not $ApiKey) {
        Write-Host "  To enable write operations (adding papers, managing collections,"
        Write-Host "  updating metadata), you'll need a Zotero API key."
        Write-Host ""
        Write-Host "  Note: You'll need to be logged in to Zotero on the web."
        Write-Host "  If you haven't verified your email with Zotero yet, you"
        Write-Host "  may need to do that first."
        Write-Host ""
        Write-Host "  1. Go to this URL:"
        Write-Host ""
        Write-Host "     https://www.zotero.org/settings/keys"
        Write-Host ""
        Write-Host "     (If that link doesn't work, go to zotero.org, log in,"
        Write-Host "      then navigate to Settings > Feeds/API)"
        Write-Host "  2. Click 'Create new private key'"
        Write-Host "  3. Give it a name (e.g., 'Claude MCP')"
        Write-Host "  4. Under 'Personal Library', check ALL of these:"
        Write-Host "       - Allow library access"
        Write-Host "       - Allow write access"
        Write-Host "       - Allow notes access"
        Write-Host "  5. Click 'Save Key' and copy the key shown"
        Write-Host ""
        $ApiKey = Read-Host "  Enter your Zotero API Key (or press Enter to skip)"

        if ($ApiKey) {
            Write-Host ""
            Write-Host "  Now we need your Zotero User ID."
            Write-Host ""
            Write-Host "  Go back to this URL:"
            Write-Host ""
            Write-Host "     https://www.zotero.org/settings/keys"
            Write-Host ""
            Write-Host "  Your User ID is the number labeled 'Your userID for"
            Write-Host "  use in API calls' - it's NOT your username."
            Write-Host ""
            $LibraryId = Read-Host "  Enter your Zotero User ID"

            if ($LibraryId) {
                Success "API credentials captured"
                Pause-Script 0.3
            } else {
                Warn "No User ID provided. Configuring local-only mode."
                $EnableWrite = $false
                $ApiKey = ""
            }
        } else {
            Warn "Skipping API key setup."
            $EnableWrite = $false
            if ($AccessMode -eq "web") {
                Fail "Web API mode requires an API key. Switching to local-only mode."
                $AccessMode = "local"
            }
            Write-Host ""
            Info "The MCP will work in read-only local mode."
            Info "You can re-run this script later to add write support."
        }
    }
}

# ============================================================================
# STEP 3: Install uv
# ============================================================================

Section "Installing Dependencies"

if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvVer = try { uv --version 2>$null } catch { "version unknown" }
    Success "uv is already installed ($uvVer)"
} else {
    Info "Installing uv (Python package manager)..."

    # Attempt 1: PowerShell installer
    $uvInstalled = $false
    try {
        irm https://astral.sh/uv/install.ps1 | iex
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            $uvInstalled = $true
        }
    } catch { }

    # Attempt 2: Try winget
    if (-not $uvInstalled) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Warn "Direct install failed. Trying winget..."
            try {
                winget install astral-sh.uv --silent 2>$null
                $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
                if (Get-Command uv -ErrorAction SilentlyContinue) {
                    $uvInstalled = $true
                }
            } catch { }
        }
    }

    if ($uvInstalled) {
        Success "uv installed"
    } else {
        Fail "Could not install uv automatically."
        Write-Host ""
        Write-Host "   Please try one of these in PowerShell:"
        Write-Host ""
        Write-Host "     Option 1: irm https://astral.sh/uv/install.ps1 | iex"
        Write-Host "     Option 2: winget install astral-sh.uv"
        Write-Host ""
        Write-Host "   Then run this installer script again."
        exit 1
    }
}

# ============================================================================
# STEP 4: Install Zotero MCP Server
# ============================================================================

Section "Installing Zotero MCP Server"
Info "Please wait while we download and install the server"
Info "with all dependencies (may take a minute or two)..."
Write-Host ""

# Remove old pip version
if (Get-Command pip -ErrorAction SilentlyContinue) {
    try {
        $pipCheck = pip show zotero-mcp-server 2>$null
        if ($pipCheck) {
            Warn "Removing old pip-installed version..."
            pip uninstall zotero-mcp-server -y 2>$null
        }
    } catch { }
}

# Determine install source
if ($eugene) {
    $InstallPkg = "zotero-mcp-server[all] @ git+https://github.com/ehawkin/zotero-mcp@secret"
    Info "Installing from Eugene's fork (latest development version)..."
} else {
    $InstallPkg = "zotero-mcp-server[all]"
}

# First attempt
$installSuccess = $false
$uvList = try { uv tool list 2>$null } catch { "" }
if ($uvList -match "zotero-mcp-server") {
    uv tool install --force --reinstall $InstallPkg 2>$null
} else {
    uv tool install $InstallPkg 2>$null
}

if ($LASTEXITCODE -eq 0) {
    $installSuccess = $true
} else {
    # Second attempt: clear cache and retry with visible output
    Warn "First install attempt failed. Retrying..."
    try { uv cache clean 2>$null } catch { }
    Write-Host ""
    uv tool install --force --reinstall $InstallPkg 2>&1
    if ($LASTEXITCODE -eq 0) {
        $installSuccess = $true
    }
}

if (-not $installSuccess) {
    Write-Host ""
    Fail "Server installation failed."
    Write-Host ""
    Write-Host "   Please try running the following command in PowerShell:"
    Write-Host ""
    Write-Host "     uv tool install --force $InstallPkg"
    Write-Host ""
    Write-Host "   Once that completes, run this installer script again"
    Write-Host "   to finish the setup."
    exit 1
}

if ($eugene) {
    Success "Zotero MCP server installed (from Eugene's fork)"
} else {
    Success "Zotero MCP server installed"
}
Pause-Script 0.5

# Ensure ~/.local/bin is in PATH
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"

# Find executable
$ZoteroMcpPath = "$env:USERPROFILE\.local\bin\zotero-mcp.exe"
if (-not (Test-Path $ZoteroMcpPath)) {
    $found = Get-Command zotero-mcp -ErrorAction SilentlyContinue
    if ($found) { $ZoteroMcpPath = $found.Source }
}
if (-not $ZoteroMcpPath -or -not (Test-Path $ZoteroMcpPath)) {
    # Last resort: search common uv locations
    $searchResult = Get-ChildItem -Path "$env:USERPROFILE\.local" -Recurse -Filter "zotero-mcp.exe" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "*\.cache\*" } | Select-Object -First 1
    if ($searchResult) { $ZoteroMcpPath = $searchResult.FullName }
}
if (-not $ZoteroMcpPath -or -not (Test-Path $ZoteroMcpPath)) {
    Write-Host ""
    Fail "Could not locate the zotero-mcp executable."
    Write-Host ""
    Write-Host "   This usually means uv installed it in an unexpected location."
    Write-Host "   Try running: uv tool list"
    Write-Host "   Or reinstall manually: uv tool install --force $InstallPkg"
    exit 1
}

# ============================================================================
# STEP 5: Configure Claude Desktop
# ============================================================================

Section "Configuring Claude Desktop"

# Back up existing config with timestamp
if (Test-Path $ClaudeConfigFile) {
    $backupTs = Get-Date -Format "yyyy-MM-dd_HHmm"
    $backupFile = $ClaudeConfigFile -replace "\.json$", "_backup_$backupTs.json"
    try {
        Copy-Item $ClaudeConfigFile $backupFile
        Success "Config backed up to $(Split-Path $backupFile -Leaf)"
    } catch {
        Warn "Could not create config backup (continuing anyway)"
    }
}

# Build environment variables
# Mirrors lib/installer_core.py :: _build_zotero_env_vars() so the CLI and
# GUI installers write identical env blocks.
$envObj = @{ ZOTERO_LOCAL = "true" }
if ($AccessMode -eq "web") {
    $envObj = @{}
}
if ($EnableWrite -and $ApiKey -and $LibraryId) {
    $envObj["ZOTERO_API_KEY"] = $ApiKey
    $envObj["ZOTERO_LIBRARY_ID"] = $LibraryId
    $envObj["ZOTERO_LIBRARY_TYPE"] = "user"
}
if ($null -ne $AnnotationLimitValue) {
    $envObj["ZOTERO_MCP_ANNOTATION_LIMIT"] = "$AnnotationLimitValue"
}

# Embedding backend env vars (omitted entirely when local)
if ($EmbeddingModel -eq "openai") {
    $envObj["ZOTERO_EMBEDDING_MODEL"] = "openai"
    $openaiModelName = if ($EmbeddingVariant -eq "large") { "text-embedding-3-large" } else { "text-embedding-3-small" }
    $envObj["OPENAI_EMBEDDING_MODEL"] = $openaiModelName
    if ($OpenAIKey) {
        $envObj["OPENAI_API_KEY"] = $OpenAIKey
    }
} elseif ($EmbeddingModel -eq "gemini") {
    $envObj["ZOTERO_EMBEDDING_MODEL"] = "gemini"
    $envObj["GEMINI_EMBEDDING_MODEL"] = "gemini-embedding-001"
    if ($GeminiKey) {
        $envObj["GEMINI_API_KEY"] = $GeminiKey
    }
}

$modeLabel = switch ($AccessMode) {
    "hybrid" { "hybrid (read + write)" }
    "local"  { "local-only (read)" }
    "web"    { "web API" }
}

try {
    # Load existing config (PS 5.1 compatible)
    $config = @{}
    if (Test-Path $ClaudeConfigFile) {
        try {
            $raw = Get-Content $ClaudeConfigFile -Raw | ConvertFrom-Json
            $config = ConvertTo-Hashtable $raw
        } catch { $config = @{} }
    }

    if (-not $config.ContainsKey("mcpServers")) { $config["mcpServers"] = @{} }
    if ($config["mcpServers"] -isnot [hashtable]) {
        $config["mcpServers"] = ConvertTo-Hashtable $config["mcpServers"]
    }
    $config["mcpServers"]["zotero"] = @{
        command = $ZoteroMcpPath
        env = $envObj
    }

    # Write without BOM
    Write-JsonNoBom $ClaudeConfigFile $config

    Success "Claude Desktop configured for $modeLabel mode"
} catch {
    Warn "Could not write Claude config automatically."
    Write-Host ""
    Write-Host "   Please edit your Claude Desktop config file:"
    Write-Host "   $ClaudeConfigFile"
    Write-Host ""
    Write-Host "   Add a 'zotero' entry inside 'mcpServers' with:"
    Write-Host "     command: $ZoteroMcpPath"
    if ($EnableWrite -and $ApiKey) {
        Write-Host "     env: ZOTERO_LOCAL=true, ZOTERO_API_KEY=$ApiKey, ZOTERO_LIBRARY_ID=$LibraryId"
    } else {
        Write-Host "     env: ZOTERO_LOCAL=true"
    }
    Write-Host ""
}
Pause-Script 0.5

# ============================================================================
# STEP 6: Configure Semantic Search
# ============================================================================

if ($EnableSemantic) {
    Section "Configuring Semantic Search"
    try {
        $semConfigDir = "$env:USERPROFILE\.config\zotero-mcp"
        $semConfigFile = "$semConfigDir\config.json"
        New-Item -ItemType Directory -Path $semConfigDir -Force | Out-Null

        # Load existing config (PS 5.1 compatible)
        $semConfig = @{}
        if (Test-Path $semConfigFile) {
            try {
                $raw = Get-Content $semConfigFile -Raw | ConvertFrom-Json
                $semConfig = ConvertTo-Hashtable $raw
            } catch { $semConfig = @{} }
        }

        if (-not $semConfig.ContainsKey("semantic_search")) { $semConfig["semantic_search"] = @{} }
        $ss = $semConfig["semantic_search"]
        if ($ss -isnot [hashtable]) { $ss = ConvertTo-Hashtable $ss; $semConfig["semantic_search"] = $ss }
        if (-not $ss.ContainsKey("update_config")) { $ss["update_config"] = @{} }
        $ss["update_config"]["auto_update"] = $true
        $ss["update_config"]["update_frequency"] = "startup"

        if (-not $ss.ContainsKey("extraction")) { $ss["extraction"] = @{} }
        $ss["extraction"]["pdf_max_pages"] = $PdfIndexPages
        $ss["extraction"]["fulltext_display_max_pages"] = $PdfDisplayPages

        # Persist embedding choice. Runtime reads this whether or not env
        # vars are present; upstream expects "default"/"openai"/"gemini" at
        # the semantic_search root, and (for non-default) an embedding_config
        # block naming the variant. Matches installer_core.py Step 4.
        if ($EmbeddingModel -eq "openai") {
            $ss["embedding_model"] = "openai"
            $openaiModelName = if ($EmbeddingVariant -eq "large") { "text-embedding-3-large" } else { "text-embedding-3-small" }
            $ss["embedding_config"] = @{ model_name = $openaiModelName }
        } elseif ($EmbeddingModel -eq "gemini") {
            $ss["embedding_model"] = "gemini"
            $ss["embedding_config"] = @{ model_name = "gemini-embedding-001" }
        } else {
            $ss["embedding_model"] = "default"
            if ($ss.ContainsKey("embedding_config")) { $ss.Remove("embedding_config") }
        }

        # Write without BOM
        Write-JsonNoBom $semConfigFile $semConfig

        Success "Auto-update on startup: enabled"
        if ($FullTextIndex) {
            Success "Full-text indexing: enabled"
        } else {
            Info "Full-text indexing: disabled (metadata-only index)"
        }
        Success "PDF indexing limit: $PdfIndexPages pages"
        Success "Display limit: $PdfDisplayPages pages"
        $embLabel = switch ($EmbeddingModel) {
            "openai" { "OpenAI ($openaiModelName)" }
            "gemini" { "Gemini (gemini-embedding-001)" }
            default  { "local (default)" }
        }
        Success "Embedding backend: $embLabel"
    } catch {
        Warn "Could not write semantic search config. Default settings will be used."
    }
}

# ============================================================================
# STEP 7: Build Semantic Search Database
# ============================================================================

if ($BuildDb) {
    Section "Semantic Search Database"

    $dbPath = "$env:USERPROFILE\.config\zotero-mcp\chroma_db"
    if (Test-Path $dbPath) {
        Write-Host "  An existing search database was found."
        Write-Host ""
        Write-Host "  Rebuilding will apply your updated settings and index any"
        Write-Host "  new papers, which may improve search quality."
        Write-Host "  This takes 5-15 minutes."
        Write-Host ""
        Write-Host "  Recommended: Yes"
        $rebuildReply = Read-Host "  Rebuild now? (Y/n)"
        if ($rebuildReply -match "^[Nn]") {
            Info "Keeping existing database."
            $rebuildHint = if ($FullTextIndex) {
                "$ZoteroMcpPath update-db --force-rebuild --fulltext"
            } else {
                "$ZoteroMcpPath update-db --force-rebuild"
            }
            Write-Host "   To rebuild later, re-run this script or run:"
            Write-Host "   $rebuildHint"
            $BuildDb = $false
        }
    }

    if ($BuildDb) {
        # Retry loop for Zotero connectivity
        $connected = $false
        while (-not $connected) {
            $zoteroStatus = "not_running"
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:23119/api/users/0/items?limit=1" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                $connected = $true
                $zoteroStatus = "ready"
            } catch {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 403) {
                    $zoteroStatus = "api_disabled"
                }
            }

            if ($connected) { break }

            if ($zoteroStatus -eq "api_disabled") {
                Write-Host ""
                Warn "Zotero is running, but the local API is not enabled."
                Write-Host ""
                Write-Host "   Please enable this setting in Zotero:"
                Write-Host ""
                Write-Host "      Edit > Settings > Advanced"
                Write-Host ""
                Write-Host "      [x] Allow other applications on this computer"
                Write-Host "          to communicate with Zotero"
                Write-Host ""
                Write-Host "   Once enabled, press Enter to try again"
                Write-Host "   or type S to skip the database build."
            } else {
                Write-Host ""
                Warn "Cannot connect to Zotero."
                Write-Host ""
                Write-Host "   Please make sure Zotero is running, and that this"
                Write-Host "   setting is enabled:"
                Write-Host ""
                Write-Host "      Edit > Settings > Advanced"
                Write-Host ""
                Write-Host "      [x] Allow other applications on this computer"
                Write-Host "          to communicate with Zotero"
                Write-Host ""
                Write-Host "   Press Enter to try again or type S to skip."
            }
            Write-Host ""
            $retryReply = Read-Host "   [Enter to retry / S to skip]"
            if ($retryReply -match "^[Ss]") {
                Info "Skipping database build."
                $skipHint = if ($FullTextIndex) { "$ZoteroMcpPath update-db --fulltext" } else { "$ZoteroMcpPath update-db" }
                Write-Host "   Start Zotero with the setting enabled, then run:"
                Write-Host "   $skipHint"
                Write-Host "   Or just open Claude Desktop - it will build automatically."
                $BuildDb = $false
                break
            }
        }

        if ($BuildDb) {
            Write-Host ""
            if ($FullTextIndex) {
                Info "Building semantic search database with full-text indexing..."
                Info "This indexes the content of your papers for better search."
            } else {
                Info "Building semantic search database (metadata only)..."
                Info "Titles and abstracts will be indexed. Re-run with -IndexDepth full to add paper content."
            }
            Write-Host ""
            Info "You can start using the MCP in Claude Desktop while this runs."
            Info "All tools work immediately - semantic search results will"
            Info "improve once the build completes."
            Write-Host ""

            $env:ZOTERO_LOCAL = "true"
            # Mirror embedding env vars into the update-db subprocess so indexing
            # uses the chosen backend right away. (Runtime Claude calls read these
            # from claude_desktop_config.json, but this subprocess doesn't.)
            foreach ($kv in $envObj.GetEnumerator()) {
                $k = $kv.Key
                if ($k.StartsWith("ZOTERO_EMBEDDING") -or $k.StartsWith("OPENAI_") -or $k.StartsWith("GEMINI_")) {
                    Set-Item -Path "Env:$k" -Value $kv.Value
                }
            }

            # Assemble update-db arguments; --fulltext only when requested
            $dbArgs = @("update-db")
            if ($FullTextIndex) { $dbArgs += "--fulltext" }
            $retryHint = if ($FullTextIndex) { "$ZoteroMcpPath update-db --fulltext" } else { "$ZoteroMcpPath update-db" }

            try {
                & $ZoteroMcpPath @dbArgs
                Write-Host ""
                Success "Semantic search database built"
                Pause-Script 0.5
            } catch {
                Write-Host ""
                $dbPath2 = "$env:USERPROFILE\.config\zotero-mcp\chroma_db"
                if (Test-Path $dbPath2) {
                    Warn "Database build had issues. A partial database may exist."
                    Write-Host "   To rebuild from scratch:"
                    Write-Host "   $retryHint --force-rebuild"
                } else {
                    Warn "Database build had issues. You can try again later with:"
                    Write-Host "   $retryHint"
                }
            }
        }
    }
}

# ============================================================================
# STEP 8: Complete!
# ============================================================================

Pause-Script 1

Write-Host ""
Write-Host ""
Write-Host "  $([char]0x2713) Installation Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  To start using Zotero MCP:"
Write-Host ""
Write-Host "  1. Make sure Zotero is running"
Write-Host "  2. Open Claude Desktop (restart if already open)"
Write-Host "  3. Start chatting! Try:"
Write-Host "     'What papers are in my library about [topic]?'"
Write-Host ""
Write-Host "  ========================================================" -ForegroundColor Red
Write-Host "  IMPORTANT:" -ForegroundColor Red -NoNewline; Write-Host " In Zotero, go to:"
Write-Host "    Edit > Settings > Advanced"
Write-Host "  and make sure this is " -NoNewline; Write-Host "CHECKED:" -ForegroundColor Red
Write-Host "    $([char]0x2611) Allow other applications on this computer" -ForegroundColor Cyan
Write-Host "      to communicate with Zotero" -ForegroundColor Cyan
Write-Host "  Without this, the MCP cannot connect!" -ForegroundColor Red
Write-Host "  ========================================================" -ForegroundColor Red
Write-Host ""

# Show setup summary
if ($EnableWrite -and $ApiKey) {
    Write-Host "  Your setup: " -NoNewline; Write-Host "Hybrid mode (read + write)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Claude can search, add papers by DOI, manage collections,"
    Write-Host "  tag items, create notes, find duplicates, and more."
} elseif ($AccessMode -eq "web") {
    Write-Host "  Your setup: " -NoNewline; Write-Host "Web API mode" -ForegroundColor Yellow
    Write-Host "  Re-run this script to switch to hybrid mode."
} else {
    Write-Host "  Your setup: " -NoNewline; Write-Host "Local-only mode (read access)" -ForegroundColor Yellow
    Write-Host "  Re-run this script to add write support."
}

if (-not $EnableSemantic) {
    Write-Host ""
    Write-Host "  Semantic search: Not configured."
    Write-Host "  To enable, re-run this script."
}

Write-Host ""
Write-Host "  ========================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  If you have any issues, run the diagnostic tool:"
Write-Host "    powershell -ExecutionPolicy Bypass -File install-zotero-mcp.ps1 -diagnose"
Write-Host ""
