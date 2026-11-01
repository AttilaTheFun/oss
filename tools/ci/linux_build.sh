#!/bin/bash
# oss's command line built for Linux, as a client runs it there (in a
# session's container, on a Linux CI runner): `swift build --product oss` in
# a container leased from OS Server, of Visor's agent image (Swift 6.4,
# aarch64, with Rosetta), so the Linux client keeps building.
#
#   tools/ci/linux_build.sh
#
#   OSS_CI_IMAGE  the image (default: Visor's agent image, below)
#
# The committed tree goes in on the command's standard input (git archive)
# and the build runs where it lands: everything through `oss machine run
# container --inside`, whose exec goes through the server's API from a user
# who can't reach the container's socket (CI's runner is a user of its
# own). `run` holds a five-minute lease renewed while it runs, and releases
# it however it ends: SIGTERM (the runner's cancel) releases it at once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${OSS_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.41.2}"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"

# The build, in the container: the tree unpacked into /tmp/oss, then the
# command line, which then says what it is.
build='set -e
mkdir -p /tmp/oss && tar -x -C /tmp/oss && cd /tmp/oss
swift --version
swift build --product oss
.build/debug/oss --help | head -1'

# The tree from a file, not a pipe: exec then makes oss this process, so the
# runner's cancel reaches it, and it releases the container. The file is in
# the job's own temporary folder, which the runner empties after the job.
# On OS Server's own runner, a container of that image already: built in place.
if [ "$(uname)" = Linux ]; then
    cd "$ROOT" && exec sh -c "swift --version && swift build --product oss && .build/debug/oss --help | head -1"
fi

tree="${RUNNER_TEMP:-$(mktemp -d)}/oss-tree.tar"
git -C "$ROOT" archive --format=tar -o "$tree" HEAD
exec "$OSS" machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=8 --inside --workdir=/ -- sh -c "$build" < "$tree"
