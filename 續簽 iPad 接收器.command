#!/bin/bash
set -eu
cd "$(dirname "$0")"
exec /usr/bin/python3 scripts/renew-receiver.py --launch-url 'autosidecar-companion://usb'
