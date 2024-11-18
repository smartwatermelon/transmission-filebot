#!/usr/bin/env bash
set -ex -o pipefail

# bail if TR_TORRENT_DIR is not set
test -z "${TR_TORRENT_DIR}" && exit 1

# bail if we can't pushd to TR_TORRENT_DIR
pushd "${TR_TORRENT_DIR}" || exit 1

# delete common non-video garbage files
find . -name '*nfo' -delete
find . -name '*exe' -delete
find . -name '*txt' -delete

# return to starting dir
popd
