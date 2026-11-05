#!/bin/bash
# Runs once, on first start of an empty data volume.
# Creates an app user that can only read/write its own database (no admin rights).
set -e

mongosh --quiet \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin <<EOF
use $MONGO_APP_DB
db.createUser({
  user: "$MONGO_APP_USER",
  pwd: "$MONGO_APP_PASSWORD",
  roles: [{ role: "readWrite", db: "$MONGO_APP_DB" }]
})
EOF
