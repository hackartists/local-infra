#!/usr/bin/zsh

source /home/hackartist/.zshrc
MSG_ID=$1

mkdir -p /tmp/slack/$MSG_ID
cd /tmp/slack/$MSG_ID

uuid=`python3 -c 'import uuid, sys; print(uuid.uuid3(uuid.NAMESPACE_DNS, sys.argv[1]))' "$MSG_ID"`

claude -p "$MSG_ID is a message id of slack. Categorize the message into one of the following categories: github issue, coding, question, or other. Then, write the category in a file named category.txt. And write TODOs in a file named todo.txt" --session-id $uuid

