#!/usr/bin/zsh

source /home/hackartist/.zshrc
MSG_ID=$1

mkdir -p /tmp/slack/$MSG_ID
cd /tmp/slack/$MSG_ID

uuid=`python3 -c 'import uuid, sys; print(uuid.uuid3(uuid.NAMESPACE_DNS, sys.argv[1]))' "$MSG_ID"`

claude -p "Reply to $MSG_ID slack message." --session-id $uuid

