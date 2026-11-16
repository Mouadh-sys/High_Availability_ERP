#!/usr/bin/env python3
"""T08 helper — create an ir.attachment through Odoo's XML-RPC API and read it back.

Prints one JSON object:
  {"id": 42, "name": "...", "size": 65536, "checksum": "<sha1>",
   "store_fname": "ab/abcdef...", "verified": true}

Environment:
  ODOO_URL              base URL (default http://127.0.0.1:8069)
  ODOO_DB               database name (default ha_erp)
  ODOO_ADMIN_USER       login (default admin)
  ODOO_ADMIN_PASSWORD   required
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import sys
import xmlrpc.client

url = os.environ.get("ODOO_URL", "http://127.0.0.1:8069").rstrip("/")
db = os.environ.get("ODOO_DB", "ha_erp")
user = os.environ.get("ODOO_ADMIN_USER", "admin")
password = os.environ.get("ODOO_ADMIN_PASSWORD")

if not password:
    sys.exit("ODOO_ADMIN_PASSWORD is not set")

common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common", allow_none=True)
models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object", allow_none=True)

uid = common.authenticate(db, user, password, {})
if not uid:
    sys.exit(f"XML-RPC authentication failed for {user}@{db} via {url}")

payload = secrets.token_bytes(64 * 1024)
name = f"ha-erp-test-{secrets.token_hex(4)}.bin"

att_id = models.execute_kw(
    db, uid, password, "ir.attachment", "create",
    [{
        "name": name,
        "datas": base64.b64encode(payload).decode("ascii"),
        "mimetype": "application/octet-stream",
    }],
)

fields = models.execute_kw(
    db, uid, password, "ir.attachment", "read",
    [[att_id], ["checksum", "store_fname", "file_size"]],
)[0]
datas = models.execute_kw(
    db, uid, password, "ir.attachment", "read",
    [[att_id], ["datas"]],
)[0]["datas"]

decoded = base64.b64decode(datas or "")
result = {
    "id": att_id,
    "name": name,
    "size": len(payload),
    "checksum": fields.get("checksum"),
    "store_fname": fields.get("store_fname"),
    "file_size": fields.get("file_size"),
    "sha1": hashlib.sha1(payload).hexdigest(),
    "verified": decoded == payload,
}
print(json.dumps(result))
