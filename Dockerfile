# ABOUTME: Docker image for Claude Code with pre-configured MCP servers
# ABOUTME: Provides autonomous Claude Code environment with Telegram notifications

FROM node:trixie-slim

# delete default node user if exists
# we will likely need his UID
RUN deluser node || true
RUN delgroup node || true

# Install Node.js and required system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    build-essential \
    sudo \
    gettext-base \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install additional system packages if specified
ARG SYSTEM_PACKAGES=""
RUN if [ -n "$SYSTEM_PACKAGES" ]; then \
    # Add Microsoft package repo if any dotnet packages are requested (Debian 13/Trixie)
    if echo "$SYSTEM_PACKAGES" | grep -q "dotnet"; then \
        echo "Adding Microsoft package repository for .NET..." && \
        wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb && \
        dpkg -i /tmp/packages-microsoft-prod.deb && \
        rm -f /tmp/packages-microsoft-prod.deb; \
    fi && \
    echo "Installing additional system packages: $SYSTEM_PACKAGES" && \
    apt-get update && \
    apt-get install -y $SYSTEM_PACKAGES && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "No additional system packages specified"; \
fi

# Create a non-root user with matching host UID/GID
ARG USER_UID=1000
ARG USER_GID=1000
RUN if getent group $USER_GID > /dev/null 2>&1; then \
        GROUP_NAME=$(getent group $USER_GID | cut -d: -f1); \
    else \
        groupadd -g $USER_GID claude-user && GROUP_NAME=claude-user; \
    fi && \
    useradd -m -s /bin/bash -u $USER_UID -g $GROUP_NAME claude-user && \
    echo "claude-user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Create app directory
WORKDIR /app

# Claude Code will be installed via native installer after switching to claude-user
ARG CC_VERSION=""

# Pre-install MCP server packages globally (avoids permission issues at runtime)
RUN npm install -g mcp-communicator-telegram @playwright/mcp
# Install Playwright browser (chromium only to save space)
RUN npx playwright install --with-deps chromium

# Ensure npm global bin is in PATH
ENV PATH="/usr/local/bin:${PATH}"

# Create directories for configuration
RUN mkdir -p /app/.claude /home/claude-user/.claude

# Copy startup and statusline scripts
COPY src/startup.sh /app/
COPY src/statusline.sh /app/

# Copy .claude directory for runtime use
COPY .claude /app/.claude

# Copy .env file during build to bake credentials into the image
# This enables one-time setup - no need for .env in project directories
COPY .env /app/.env

# Copy CLAUDE.md template directly to final location
COPY .claude/CLAUDE.md /home/claude-user/.claude/CLAUDE.md

# Copy Claude authentication files from host
# Note: These must exist - host must have authenticated Claude Code first
COPY .claude.json /tmp/.claude.json

# Copy MCP server configuration files (as root)
COPY mcp-servers.txt mcp-servers-dotnet.txt /app/
COPY install-mcp-servers.sh /app/

# Fix Windows CRLF line endings and set executable bits on all shell scripts/text files
RUN sed -i 's/\r$//' /app/startup.sh /app/statusline.sh /app/install-mcp-servers.sh /app/mcp-servers.txt /app/mcp-servers-dotnet.txt /app/.env && \
    chmod +x /app/startup.sh /app/statusline.sh /app/install-mcp-servers.sh

# Move auth files to proper location before switching user
RUN cp /tmp/.claude.json /home/claude-user/.claude.json && \
    rm -f /tmp/.claude.json

# Set proper ownership for everything (including npm global dir so auto-update works)
RUN chown -R claude-user /app /home/claude-user /usr/local/lib/node_modules /usr/local/bin

# Switch to non-root user
USER claude-user

# Set HOME immediately after switching user
ENV HOME=/home/claude-user

# Install Claude Code via native installer as claude-user (supports auto-update)
RUN curl -fsSL https://claude.ai/install.sh | bash
# If a specific version was requested, pin that version via npm
RUN if [ -n "$CC_VERSION" ]; then \
        echo "Pinning Claude Code version: $CC_VERSION" && \
        npm install -g @anthropic-ai/claude-code@$CC_VERSION; \
    fi

# Install uv (Astral) for claude-user for Serena MCP (todo make this modular.)
# Note: Will be installed for claude-user after user creation
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Add claude-user's local bin and native Claude installer path to PATH
ENV PATH="/home/claude-user/.claude/local/bin:/home/claude-user/.local/bin:/home/claude-user/.dotnet/tools:${PATH}"

# Install .NET MCP tools if enabled and dotnet SDK is available
ARG ENABLE_DOTNET_MCP="false"
RUN if [ "$ENABLE_DOTNET_MCP" = "true" ] && command -v dotnet >/dev/null 2>&1; then \
        echo "Installing .NET MCP server tools..." && \
        dotnet tool install --global NuGet.Mcp.Server && \
        dotnet tool install --global DimonSmart.NugetMcpServer && \
        dotnet tool install --global csharp-ls && \
        git clone --depth 1 https://github.com/HYMMA/csharp-lsp-mcp.git /tmp/csharp-lsp-mcp && \
        dotnet publish /tmp/csharp-lsp-mcp/csharp-lsp-mcp/src/CSharpLspMcp -c Release -o /home/claude-user/.dotnet/tools && \
        rm -rf /tmp/csharp-lsp-mcp && \
        echo ".NET MCP tools installed successfully"; \
    elif [ "$ENABLE_DOTNET_MCP" = "true" ]; then \
        echo "⚠ ENABLE_DOTNET_MCP=true but no .NET SDK found — add dotnet-sdk-* to SYSTEM_PACKAGES"; \
    else \
        echo "Skipping .NET MCP tools (ENABLE_DOTNET_MCP not set)"; \
    fi

# Install MCP servers from configuration file
RUN /app/install-mcp-servers.sh

# Configure git user during build using host git config passed as build args
ARG GIT_USER_NAME=""
ARG GIT_USER_EMAIL=""
RUN if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then \
        echo "Configuring git user from host: $GIT_USER_NAME <$GIT_USER_EMAIL>" && \
        git config --global user.name "$GIT_USER_NAME" && \
        git config --global user.email "$GIT_USER_EMAIL" && \
        echo "Git configuration complete"; \
    else \
        echo "Warning: No git user configured on host system"; \
        echo "Run 'git config --global user.name \"Your Name\"' and 'git config --global user.email \"you@example.com\"' on host first"; \
    fi

# Set working directory to mounted volume
WORKDIR /workspace

# Do not set NODE_ENV=production — it interferes with Claude Code's auto-updater

# Start both MCP server and Claude Code
ENTRYPOINT ["/app/startup.sh"]
