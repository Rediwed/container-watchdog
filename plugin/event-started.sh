#!/bin/bash

# Register the persistent cron source and publish an initial status after services start.
/usr/local/sbin/update_cron
/usr/local/sbin/container-watchdog-status >/dev/null 2>&1 || true
