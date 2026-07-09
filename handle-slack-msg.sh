#!/usr/bin/env zsh

source ~/.zshrc
MSG_ID=$1

mkdir -p /tmp/slack/$MSG_ID
cd /tmp/slack/$MSG_ID

uuid=`python3 -c 'import uuid, sys; print(uuid.uuid3(uuid.NAMESPACE_DNS, sys.argv[1]))' "$MSG_ID"`

PROMPT="Check and handle slack message $MSG_ID. Then, reply results to $MSG_ID"

# Resume the deterministic session for this message if it exists,
# otherwise start a new session with that id.
claude -p "$PROMPT" -r "$uuid" || claude -p "$PROMPT" --session-id "$uuid"

