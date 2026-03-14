# CORE EXECUTION PROTOCOL
THESE RULES ARE ABSOLUTE AND APPLY AT ALL TIMES.

## General

### 1. STARTUP PROCEDURE
- **FIRST & ALWAYS**: IF project dir has existing code, we MUST index the codebase using Serena MCP.
  `uvx --from git+https://github.com/oraios/serena index-project`

### 2. TASK CLARIFICATION PROTOCOL
- **MANDATORY CLARIFICATION**: If the user's prompt contains ANY vagueness or insufficient detail related to the goal being implied, you MUST ask clarifying questions before proceeding.

### 3A. SYSTEM PACKAGE INSTALLATION PROTOCOL
- **APT-GET SYSTEM PACKAGES**: USE `sudo apt-get install` to install missing system packages when required for the task. You must create a `missing_packages.txt` file in the project `.claude` dir if this is required, create a `.claude` dir if one does not already exist at the project level.

### 3B. PYTHON/CONDA ENVIRONMENT EXECUTION PROTOCOL
- **MANDATORY CONDA BINARY**:
  ALWAYS use the conda binary at `$CONDA_PREFIX/bin/conda` for all environment and script execution commands.

- **SCRIPT EXECUTION FORMAT**:
  ALWAYS follow these steps for PYTHON script execution:
  
  1. **First, list conda environments to get Python binary paths**:
  ```bash
  ${CONDA_EXE:-conda} env list
  ```
  
  2. **Then execute Python scripts using the direct binary path**:
  ```bash
  /path/to/environment/bin/python your_script.py [args]
  ```
  - Replace `/path/to/environment/bin/python` with the actual Python binary path from step 1.
  - Replace `your_script.py [args]` with the script and its arguments.

### 3C. PATH USAGE PROTOCOL
- **MANDATORY RELATIVE PATHS**: ALL scripts MUST use relative paths, NEVER absolute paths.
- **ABSOLUTE PATH PROHIBITION**: 
  - **NEVER** hardcode `/workspace` or any other absolute path in scripts.
  - **NEVER** use absolute paths like `/data2/vj724/claude-docker/...` or `/workspace/...` in script code.
- **EXCEPTIONS**: Only system binaries and environment-specific paths (like conda Python binaries) may use absolute paths, but never project-specific paths.

### 4. CODEBASE CONTEXT MAINTENANCE PROTOCOL
- All PYTHON scripts MUST use the `argparse` module for command-line argument handling. This ensures consistent, robust, and self-documenting CLI interfaces for all scripts.
- **MANDATORY CONTEXT.MD MAINTENANCE**: The `context.md` file MUST be maintained and updated by EVERY agent working on the codebase.
- **PURPOSE**: `context.md` provides a high-level architectural overview of the codebase, eliminating the need for future agents to scan the entire codebase for understanding.
- **CONTENT REQUIREMENTS**: `context.md` MUST contain:
  - **MODULE ARCHITECTURE**: Clear mapping of all key modules/scripts and their primary responsibilities
  - **DATA FLOW**: How data flows between different components
  - **DEPENDENCIES**: Key dependencies between modules and external libraries
  - **ENTRY POINTS**: Main execution entry points and their purposes
  - **CONFIGURATION**: How configuration is managed across the system
  - **CORE LOGIC**: Summary of the core logic each module handles
- **UPDATE FREQUENCY**: 
  - **IMMEDIATE**: Update `context.md` whenever new modules are created
  - **AFTER LOGIC CHANGES**: Update whenever core logic in existing modules is modified
  - **BEFORE COMMITS**: Ensure `context.md` is current before any commit
- **STRUCTURE**: Use clear headings, bullet points, and code examples where helpful
- **NO EXCEPTIONS**: This file is CRITICAL for maintaining agent productivity and MUST be kept current

### 5. TELEGRAM NOTIFICATION PROTOCOL
- **ALWAYS SEND A TELEGRAM MESSAGE** when:
    1. **TASK COMPLETE**: You finished what the user asked for.
    2. **BLOCKED / NEED INPUT**: You are stuck, hit an error, or need a decision from the user.
    3. **LONG-RUNNING TASK MILESTONE**: A significant step is done and another is starting.
- **MESSAGE FORMAT**: Always prefix with the **project folder name** so the user knows which session sent it:
    ```
    [ProjectName] Task complete: implemented user authentication
    [ProjectName] Blocked: database migration failed, need guidance
    ```
    Get the project name from the current working directory basename.
- **HOW TO SEND**:
    - Use `notify_user` for one-way status updates (task done, milestone reached).
    - Use `ask_user` when you need a response before you can continue. This will wait for the user to reply via Telegram.
- **MULTI-SESSION AWARENESS**: Multiple claude-docker sessions may share the same Telegram bot. The project name prefix is CRITICAL so the user can tell which session is talking.
- **DO NOT SKIP**: If the Telegram MCP is available, ALWAYS send notifications. Do not wait for the user to ask.

## Tool Usage

### Documentation Tools

**View Official Documentation** - 
`resolve-library-id` - Resolve library name to Context7 ID- `get-library-docs` - Get latest official documentation

**Search Real Code** - 
`searchGitHub` - Search actual use cases on GitHub 
