#!/usr/bin/env bash

version() {
  local sum="282a301f" # __VERSION_CHECKSUM_HERE__ generated by `cat main.sh lib/base.sh lib/backup.sh lib/restore.sh utils/list.sh utils/mount.sh | md5sum | cut -c -8`
  echo "v0.1.0-$sum"
}
