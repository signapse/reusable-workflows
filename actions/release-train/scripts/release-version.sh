#!/usr/bin/env bash
# release-version.sh <tag>
#
# Prints the version a Deployment is recorded under, identical in Linear and
# Sentry: "${RELEASE_PREFIX}<tag>". Several repos share one product pipeline
# and Sentry release versions are org-wide, so the default prefix is
# "<repo name>@" (from GITHUB_REPOSITORY), e.g. sign-stream-api@1.4.0.
#   RELEASE_PREFIX unset or "auto" -> "<repo name>@"
#   RELEASE_PREFIX ""              -> bare tag (pipeline with a single repo)
#   anything else                  -> used literally

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 1 ] && [ -n "$1" ] || die "usage: release-version.sh <tag>"
prefix="${RELEASE_PREFIX-auto}"
if [ "$prefix" = auto ]; then
  [ -n "${GITHUB_REPOSITORY:-}" ] || die "RELEASE_PREFIX=auto needs GITHUB_REPOSITORY"
  prefix="${GITHUB_REPOSITORY#*/}@"
fi
printf '%s%s\n' "$prefix" "$1"
