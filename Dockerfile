# =============================================================================
# Jsh Development Container
# Multi-stage build for optimized images
# =============================================================================
#
# Build: docker build -t jsh-dev .
# Run:   docker run -it --rm -v $(pwd):/home/jsh/.jsh jsh-dev
#
# Or use docker-compose:
#   docker compose up -d dev
#   docker compose exec dev /bin/zsh
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder - Download platform-specific binaries
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

# Build arguments for versions (can be overridden at build time)
ARG TARGETPLATFORM
ARG FZF_VERSION=0.67.0
ARG JQ_VERSION=1.7.1

# Install download tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download platform-specific binaries based on TARGETPLATFORM
# TARGETPLATFORM is automatically set by Docker buildx (e.g., linux/amd64, linux/arm64)
RUN set -ex; \
    case "${TARGETPLATFORM}" in \
        linux/amd64|"") \
            FZF_ARCH="linux_amd64"; \
            JQ_ARCH="linux-amd64"; \
            ;; \
        linux/arm64) \
            FZF_ARCH="linux_arm64"; \
            JQ_ARCH="linux-arm64"; \
            ;; \
        *) \
            echo "Unsupported platform: ${TARGETPLATFORM}"; \
            exit 1; \
            ;; \
    esac; \
    \
    mkdir -p bin; \
    \
    # Download fzf
    echo "Downloading fzf v${FZF_VERSION} for ${FZF_ARCH}..."; \
    curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz" \
        | tar xz -C bin; \
    \
    # Download jq
    echo "Downloading jq v${JQ_VERSION} for ${JQ_ARCH}..."; \
    curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${JQ_ARCH}" \
        -o bin/jq; \
    \
    # Make all binaries executable
    chmod +x bin/*; \
    \
    # Verify downloads
    ls -la bin/

# -----------------------------------------------------------------------------
# Stage 2: Runtime - Full development environment
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

LABEL maintainer="jsh"
LABEL description="Jsh Development Environment"
LABEL org.opencontainers.image.source="https://github.com/jaysh/jsh"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Shells
    bash \
    zsh \
    # Testing framework
    bats \
    # Linting tools
    shellcheck \
    python3-pip \
    # Version control
    git \
    # Network tools
    curl \
    ca-certificates \
    # Locale support
    locales \
    # Build tools
    make \
    # For prettier (optional)
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install yamllint via pip
RUN pip3 install --break-system-packages yamllint

# Configure locale for proper UTF-8 support
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Copy binaries from builder stage
COPY --from=builder /build/bin/* /usr/local/bin/

# Install prettier globally (for format checking)
RUN npm install -g prettier 2>/dev/null || echo "prettier install skipped"

# Create non-root user for development
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} jsh 2>/dev/null || true && \
    useradd -u ${UID} -g ${GID} -m -s /bin/zsh jsh 2>/dev/null || true

# Set up working directory
WORKDIR /home/jsh/.jsh
RUN chown -R ${UID}:${GID} /home/jsh

# Switch to non-root user
USER jsh

# Environment
ENV SHELL=/bin/zsh
ENV TERM=xterm-256color
ENV JSH_ENV=container

# Verify installed tools
RUN echo "=== Installed Tools ===" && \
    bash --version | head -1 && \
    zsh --version && \
    bats --version && \
    shellcheck --version | head -1 && \
    yamllint --version && \
    fzf --version && \
    jq --version && \
    vim --version | head -1 && \
    echo "======================="

# Default command
CMD ["/bin/zsh"]
