#!/bin/sh
# Keepalived track script: succeeds only when this node is the PostgreSQL primary.
# The role is an explicit operator decision recorded in /etc/ha-erp/db-role.
role="$(cat /etc/ha-erp/db-role 2>/dev/null || echo unknown)"
[ "$role" = "primary" ]
