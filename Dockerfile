# Runner image for the ArchUnitDev loop.
#
# Deliberately non-root: the loop runs an unattended agent with full tool access against a mounted
# repo, and a non-root user is the one thing bounding the damage a bad edit can do outside the mount.
FROM golang:1-bookworm

ARG GH_VERSION=2.65.0
# Pinned on purpose. A floating @latest linter means yesterday's green commit fails tonight,
# halfway through an unattended run, on a rule nobody chose to adopt.
ARG GOLANGCI_VERSION=v2.12.2
ARG TARGETARCH
ARG UID=1000

# apt over TLS, before the first apt-get. The Debian base image points at http://deb.debian.org, and
# the loop host only allows outbound 443 — so port 80 does not time out quickly and fail, it hangs
# until apt gives up, and the build dies two minutes in on `Could not connect to deb.debian.org:80`.
# Widening the security group to port 80 would fix it too; this is the fix that does not.
# deb822 (bookworm's default) and the older one-line format are both rewritten, since which one is
# present depends on the base image's build date. ca-certificates is already in the base image, which
# it has to be for the https transport to verify anything.
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' \
      /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list 2>/dev/null; \
    apt-get update && apt-get install -y --no-install-recommends \
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

RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/dev/.opencode/bin:${PATH}"

# safe.directory matters: the target repo is bind-mounted and will not be owned by dev.
#
# The identity is the owner's own, and the email is the part that matters. GitHub attributes a commit to
# an account by matching the *author* email against the verified addresses on it, and nothing else — not
# the pushing credential, not the committer. The address this used to carry, loop@archunitdev.invalid,
# was under a reserved TLD that can never receive mail and so can never be verified, which made every
# commit the loop landed work that belongs to no account and counts for nobody. The form below is the
# account's noreply address: the one address guaranteed to be verified, and one that publishes no real
# inbox. That the work was machine-written is recorded where it belongs — the Co-Authored-By trailer on
# every commit — rather than in an author field, where it costs the owner their own history.
RUN git config --global user.name  "Robey Beswick" \
 && git config --global user.email "88316323+RobeyBeswick@users.noreply.github.com" \
 && git config --global --add safe.directory /work/repo

# GOPATH moves under $HOME because the module cache has to be writable by dev — later issues add
# dependencies. /go in the base image is root-owned; setting this is cheaper than chowning it.
ENV GOPATH=/home/dev/go

# Warm the module cache for golang.org/x/tools, which the extractor needs for go/packages and which
# is the only third-party module the target repo takes. Worth the ~110MB (27MB of modules, 86MB of
# compiled objects): otherwise every fresh container fetches and compiles it inside the implementer's
# wall clock on the first gate run, and on a network where the module proxy is unreachable it cannot
# fetch it at all.
#
# The version is a cache key, not a constraint. If the target repo resolves a different one, go
# fetches that and this layer goes unused — a stale value here is harmless, never wrong.
#
# Compiling is the point, not downloading. `go mod download golang.org/x/tools@VERSION` fetches that
# module alone and leaves x/mod and x/sync to be fetched at run time; building something that
# imports go/packages resolves the whole graph and populates the build cache the gate reuses.
#
# GOPROXY is a build arg so the image can be built on a network where proxy.golang.org does not
# resolve — `docker build --build-arg GOPROXY=direct .`, which needs egress to go.googlesource.com.
# It is deliberately not an ENV: at run time the default proxy is the faster and narrower choice,
# and an operator who needs otherwise can pass `-e GOPROXY=direct`.
ARG GOPROXY=https://proxy.golang.org,direct
ARG XTOOLS_VERSION=v0.49.0
RUN mkdir -p /tmp/warm && cd /tmp/warm \
    && go mod init warm \
    && printf 'package warm\n\nimport _ "golang.org/x/tools/go/packages"\n' > warm.go \
    && go mod edit -require="golang.org/x/tools@${XTOOLS_VERSION}" \
    && go mod tidy \
    && go build ./... \
    && cd / && rm -rf /tmp/warm \
    && go env GOMODCACHE && du -sh "$(go env GOMODCACHE)"

COPY --chown=dev:dev . /harness
WORKDIR /harness

ENV REPO=/work/repo \
    LOGS=/work/logs

ENTRYPOINT ["/harness/run.sh"]
