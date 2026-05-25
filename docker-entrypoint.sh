#!/bin/sh
set -e

# Ensure the persisted directories exist on a fresh volume / bind mount, so the
# config loader and the --watch-directory don't error on first boot.
mkdir -p /data/gcode

exec "$@"
