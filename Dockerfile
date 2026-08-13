# Runner image for the ArchUnitDev loop.
#
# Deliberately non-root: Claude Code refuses to start with --dangerously-skip-permissions
# when running as root, and the loop depends on never blocking for a permission prompt.
FROM golang:1-bookworm

ARG GH_VERSION=2.65.0
# Pinned on purpose. A floating @latest linter means yesterday's green commit fails tonight,
# halfway through an unattended run, on a rule nobody chose to adopt.
ARG GOLANGCI_VERSION=v2.12.2
ARG TARGETARCH
ARG UID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq ripgrep awscli \
    && rm -rf /var/lib/apt/lists/*

RUN arch="${TARGETARCH:-amd64}" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
       | tar -xz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh_*

# golangci-lint is not optional: the target repo's .golangci.yml is where AGENTS.md's four
# dependency rules, the purity rule and the doc-comment rules are actually enforced, so without it
# the gate silently stops checking the architecture. run.sh refuses to start an unattended run if
# it is missing. Installed via the upstream script because it resolves the release asset name and
# architecture itself; `go install` would work too but produces a binary with no version metadata.
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
      | sh -s -- -b /usr/local/bin "${GOLANGCI_VERSION}" \
    && golangci-lint --version

RUN useradd -m -u "${UID}" dev && mkdir -p /work && chown dev:dev /work
USER dev
ENV HOME=/home/dev

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/dev/.local/bin:${PATH}"

# safe.directory matters: the target repo is bind-mounted and will not be owned by dev.
RUN git config --global user.name  "ArchUnitDev loop" \
 && git config --global user.email "loop@archunitdev.invalid" \
 && git config --global --add safe.directory /work/repo

COPY --chown=dev:dev . /harness
WORKDIR /harness

ENV REPO=/work/repo \
    LOGS=/work/logs \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Inference goes through Bedrock. AWS_PROFILE is deliberately NOT set: the host profile
# uses `credential_process = <credential-helper>`, which does not exist in here. With it
# unset, the SDK credential chain falls through to the EC2 instance profile, which refreshes
# itself and so survives a full overnight run.
ENV CLAUDE_CODE_USE_BEDROCK=1 \
    AWS_REGION=us-east-1

ENTRYPOINT ["/harness/run.sh"]
