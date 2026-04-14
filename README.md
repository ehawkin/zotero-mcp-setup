## Connecting Claude to Your Zotero Library

*Zotero MCP Setup and Configuration for use with Claude*

---

### Easy Visual Installer for Mac

**[Download the Mac Installer (DMG)](https://github.com/ehawkin/zotero-mcp-setup/releases/latest/download/ZoteroMCPSetup.dmg)** — a signed and notarized app that walks you through the entire setup with a visual interface. No Terminal needed.

Alternatively, if you prefer a one-liner in Terminal:

```
curl -sL https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/zotero-mcp-installer.py -o /tmp/zotero-mcp-installer.py && python3 /tmp/zotero-mcp-installer.py
```

*If you're on Windows, or prefer a non-visual setup, see the instructions below.*

---

### TL;DR

Use Claude to manage and interact with your entire Zotero library — search papers, add references, manage collections, read full texts, and more. To set it up:

1. Download the install script for your system:
   - **Mac:** [install-zotero-mcp.sh](https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/install-zotero-mcp.sh) — right-click the link > "Download Linked File" (or "Save Link As...")
   - **Windows:** [install-zotero-mcp.ps1](https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/install-zotero-mcp.ps1) — right-click the link > "Save link as..."
2. Install [Zotero 8](https://www.zotero.org/download/) and [Claude Desktop](https://claude.ai/download) if you don't have them already
3. In Zotero: **Settings > Advanced** > check **"Allow other applications to communicate with Zotero"**
4. Run the install script:
   - **Mac:** Open Terminal and run `bash ~/Downloads/install-zotero-mcp.sh`
     *(If macOS asks to allow Terminal to access your Downloads folder, click "Allow")*
   - **Windows:** Right-click the downloaded file > "Run with PowerShell"
5. The script walks you through everything else. When it's done, restart Claude Desktop and start chatting.

*If any of this didn't make sense, keep reading below for a more detailed step-by-step guide.*

---

### About this guide

This guide explains how to use our setup script to create a direct connection between Claude (in the Claude Desktop app) and your Zotero reference library. Once installed, you can ask Claude to search your papers, find articles on a topic, pull up details about specific references, add new papers, create collections, manage tags, and more — all through normal conversation, no special commands needed.

### What does this actually do?

Right now, Claude has no idea what's in your Zotero library. This script installs a small piece of software called an "MCP server" that acts as a bridge between Claude and Zotero. Once it's running, Claude can look through your library the same way you would — searching by title, author, keyword, or even by the *meaning* of what a paper is about (for example, asking "do I have anything about the relationship between sleep and memory consolidation?" will find relevant papers even if those exact words aren't in the title). It can also manage your library — creating collections, adding and removing tags and notes, making highlights across your documents, and more.

The script handles the entire setup automatically: it installs the necessary software, tells Claude Desktop where to find it, and builds a search index of your library.

### Before you start

Make sure you have these three things installed:

1. **Zotero 8 or later** — the desktop app, downloaded from [zotero.org/download](https://www.zotero.org/download/). You need version 8 or newer — older versions are missing features this tool depends on.
2. **Claude Desktop** — the desktop app (not the website), downloaded from [claude.ai/download](https://claude.ai/download)
3. **The install script** — download it here if you don't already have it:
   - **Mac:** [install-zotero-mcp.sh](https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/install-zotero-mcp.sh) (right-click > "Save Link As...")
   - **Windows:** [install-zotero-mcp.ps1](https://raw.githubusercontent.com/ehawkin/zotero-mcp-setup/main/install-zotero-mcp.ps1) (right-click > "Save Link As...")

You'll also need to turn on one setting in Zotero:
- **Mac:** Open Zotero > **Settings > Advanced** > check **"Allow other applications to communicate with Zotero"**
- **Windows:** Open Zotero > **Edit > Settings > Advanced** > check **"Allow other applications to communicate with Zotero"**

This is what lets Claude read your library. 

### How to run the script

#### Mac

1. Open **Terminal**: Press **Command + Space** to open Spotlight search, type **Terminal**, and hit Enter.

2. Type (or paste) the following command exactly and press Enter:

```
bash ~/Downloads/install-zotero-mcp.sh
```

**If you get an error saying the file wasn't found**, the script might not be in your Downloads folder and you will have to adjust the command to include the path to the folder where you downloaded the script. If it's on your Desktop, for example, use the command: `bash ~/Desktop/install-zotero-mcp.sh`

#### Windows

1. Find the file `install-zotero-mcp.ps1` wherever you saved it (likely Downloads).

2. **Right-click** the file and choose **"Run with PowerShell"**.

   If that option doesn't appear, open **PowerShell** from the Start menu and type (or paste):

```
powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\install-zotero-mcp.ps1"
```

If the file is on your Desktop instead: `powershell -ExecutionPolicy Bypass -File "$HOME\Desktop\install-zotero-mcp.ps1"`

**Do NOT run as Administrator** — it's not needed and can cause problems.

#### Both platforms

3. The script will first ask you to choose between **Default** and **Advanced** setup:

   - **Default (recommended):** Sets up everything automatically with the best settings — hybrid mode (fast local reads + web API for writes), semantic search enabled, and full-text indexing of your papers. You'll just need to provide an API key.
   - **Advanced:** Lets you choose your access mode (hybrid, local-only, or web API-only) and customize semantic search settings like how many pages of each PDF to index.

   For most users, Default is the right choice.

4. The script will ask you for a **Zotero API key** to enable write support (adding papers, managing collections, tagging, etc.):

   - Go to [zotero.org/settings/keys](https://www.zotero.org/settings/keys) and click "Create new private key"
   - Give it a name (like "Claude") and make sure it has **read and write access** to your personal library
   - Copy the key — it's only shown once
   - Your **User ID** is displayed on that same page (labeled "Your userID for use in API calls") — it's a number, not your username

   If you're not sure or just want to try it out first, you can press Enter to skip this step. You'll still be able to search your library — you just won't be able to manage your collection, add tags, annotations, or new documents directly from Claude. You can always re-run the script later to add write support.

5. The script will install the software and build a search index of your library. This takes a few minutes. You'll see colored status messages as it works through each step. When it's done, you'll see "Installation complete!" in green.

6. **Quit Claude Desktop completely** and reopen it.
   - **Mac:** Right-click its icon in the Dock > Quit (or Command + Q)
   - **Windows:** Right-click its icon in the system tray > Quit (or close it from Task Manager)

That's it — you're done.

### How to use it

1. **Make sure Zotero is open** on your computer. Claude can only access your library while Zotero is running.
2. **Just ask Claude.** Ask any questions you have about your library or particular papers, or ask it to make changes or additions to your library. It can pretty much do anything you can think of.

**Note:** You may briefly see a "response could not be fully generated" message when Claude is adding papers, attaching PDFs, or doing other operations that involve downloading data. This is normal — Claude is still working in the background (fetching metadata, downloading PDFs, etc.) and the message will go away once the operation finishes. Just wait a few seconds.

### Examples of what you can do

Here are some things you can ask Claude:

- **"Search my Zotero library for papers about mindfulness-based interventions"** — finds papers by topic, even if those exact words aren't in the title
- **"What papers do I have by Kingston et al.?"** — searches by author
- **"Show me the abstract for that paper about sleep and memory"** — pulls up details about a specific reference
- **"Do I have any papers from 2024 about CBT for anxiety?"** — combines multiple search criteria
- **"What are my most recently added papers?"** — shows what you've added lately
- **"Find papers in my library related to this paragraph I'm writing: [paste paragraph]"** — finds references relevant to your own writing
- **"Read the full text of that paper and summarize the methodology"** — reads the complete text of your papers, not just metadata — great for literature reviews
- **"Show me all my highlights and annotations from that paper"** — retrieves notes, highlights, and annotations you've made
- **"Show me all items in my Thesis collection"** — browses your library's collections
- **"Find papers published after 2020 by Smith about reinforcement learning"** — advanced search with multiple criteria (author, date, topic)
- **"Switch to my lab's group library and search for our recent submissions"** — works with shared/group libraries as well as your personal one

If you enabled write support during setup, you can also ask Claude to:

- **"Add this paper by DOI: 10.1038/nature12373"** — imports a paper with full metadata from CrossRef, and attaches the PDF if it's open-access
- **"Add this arXiv paper: https://arxiv.org/abs/1706.03762"** — imports arXiv preprints with metadata and PDF
- **"Create a collection called 'Thesis Chapter 3'"** — organizes your library into folders
- **"Add that paper to my Literature Review collection"** — manages collection membership
- **"Add the tag 'key-paper' to that article by Segal et al."** — tags papers from the conversation
- **"Tag all my papers about CBT with 'CBT'"** — batch-tags papers matching a search
- **"Create a summary note for this paper with the key findings"** — attaches a note directly to a paper in your library
- **"Update the abstract for that paper"** — modifies metadata (title, authors, date, tags, etc.)
- **"Find duplicate papers in my library"** — scans for duplicates by title and/or DOI
- **"Merge those duplicates — keep the first one"** — consolidates duplicates (shows a preview first, asks for confirmation, and moves duplicates to Trash where you can recover them)
- **"Extract the table of contents from that PDF"** — pulls out the outline/sections from an attached PDF
- **"Add this PDF from my computer to Zotero"** — imports a local PDF file, auto-extracts the DOI for metadata if possible

You can also combine multiple actions in a single request:

- **"What are the three most seminal papers on Predictive Coding? Can you please locate them for me and then create a predictive coding collection in my Zotero library and add those three papers?"** — Claude will look up the papers, import them by DOI, create the collection, and organize everything in one go.
- **"Take a look at the 2025 paper on digital mindfulness interventions by Wang et al. and highlight in green any sentences in the abstract, discussion, or conclusion that you feel represent the core findings."** — Claude will find the paper, read the PDF, identify the key findings, and create green highlight annotations directly on the PDF in Zotero.
- **"Go through all the papers in this collection and add a summary note to each one, including the key findings and the major limitations of the study."** — Claude will read each paper's abstract and metadata, then create a structured note attached to each one.

**About Adding PDFs:** When you ask Claude to add papers to your library, it attempts to attach open-access PDFs automatically. This works for arXiv papers (always freely available) and open-access journal articles. For paywalled papers, Claude will add all the metadata but can't download the PDF — you may need to connect to your university VPN, then in Zotero right-click the item and select "Find Available PDF", or download and import them manually.

**Claude Usage Limit Tips:** Having Claude read the full text of papers (as opposed to just searching for them or reading their metadata) uses a significant portion of your Claude usage allowance. A single paper can use 10,000+ tokens, and that cost compounds with every subsequent message in the conversation.

Tips to conserve usage:
- Ask Claude to search for papers by topic rather than asking it to read through entire papers looking for something
- If you only need specific information from a paper, tell Claude what you're looking for rather than asking it to read the whole thing
- Start a new conversation when switching to a different task, as previous paper content stays in memory and adds to usage on every subsequent message
- For simpler tasks, consider using a lighter model like Claude Sonnet. The MCP tools work the same way, but carrying the context throughout the conversation is cheaper. Good tasks for lighter models:
  -- Finding a paper with particular information
  -- Extracting results
  -- Finding specific numbers
  -- Summarizing a paper
  -- Doing a simple comparison between two papers
- We still recommend using more powerful models like Claude Opus for:
  -- Critically evaluating methodology
  -- Synthesizing across multiple papers
  -- Identifying contradictions or gaps in the literature
  -- Making nuanced judgments
  -- Generating novel arguments or framings

These tools are especially useful when you're writing a literature review, building a bibliography, looking for a citation you know you saved but can't remember the title of, or trying to find connections across papers in your library.

---

### Technical details

You don't need to read this section to use the tool — everything above is all you need. This is for anyone who wants to understand more about how it works under the hood.

**Privacy and data.** Searches happen locally between Claude Desktop and the Zotero app on your machine. If you enabled write support, modifications go through Zotero's secure cloud API (the same system Zotero already uses to sync your library) and then sync back to your desktop app within seconds.

**Two kinds of search.** Basic search (by title, author, keyword, tag) works instantly for all items — no index needed. Semantic search (by meaning — "papers about the relationship between sleep and memory") uses a separate search index. The index refreshes automatically every time you open Claude Desktop, and Claude can also refresh it during a conversation after adding papers. If semantic search ever can't find something you know is in your library, just ask Claude to "update the search database."

**Manual search index update.** If you prefer to update the search index yourself, you can run this in Terminal (Mac) or PowerShell (Windows):
- Mac: `~/.local/bin/zotero-mcp update-db --fulltext`
- Windows: `$HOME\.local\bin\zotero-mcp.exe update-db --fulltext`

To force a complete rebuild from scratch (applies new settings to all papers):
- Mac: `~/.local/bin/zotero-mcp update-db --fulltext --force-rebuild`
- Windows: `$HOME\.local\bin\zotero-mcp.exe update-db --fulltext --force-rebuild`
**Don't use `sudo` (Mac) or "Run as Administrator" (Windows).** It's not needed and can cause problems.

**Project links:**
- **Zotero MCP project:** [github.com/54yyyu/zotero-mcp](https://github.com/54yyyu/zotero-mcp)
- **This setup guide and scripts:** [github.com/ehawkin/zotero-mcp-setup](https://github.com/ehawkin/zotero-mcp-setup)
- We contributed significantly to the Zotero MCP project — our additions include 11 new tools, 20+ bug fixes, and 339 automated tests (PRs [#165](https://github.com/54yyyu/zotero-mcp/pull/165), [#170](https://github.com/54yyyu/zotero-mcp/pull/170), [#174](https://github.com/54yyyu/zotero-mcp/pull/174)).

---

### About this project

Copyright © 2026 Silver Apps LLC. The installer binaries distributed via GitHub Releases are signed and notarized by Silver Apps LLC.

This installer sets up [zotero-mcp](https://github.com/54yyyu/zotero-mcp) by 54yyyu (MIT licensed). It is not affiliated with the Zotero project or with Anthropic.

**Source availability.** This repository's source is published for transparency — so you can inspect exactly what the installer does before running it. The source is **not** currently released under an open-source license; there is no `LICENSE` file intentionally. If you'd like to reuse or redistribute parts of this code, please reach out.

**Installer is provided as-is.** Without warranty of any kind. Your Claude Desktop config is backed up automatically before any changes are made. The installer does not collect any data about you or your usage.
