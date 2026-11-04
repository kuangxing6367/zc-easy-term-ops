#!/usr/bin/env bash
# 命令替换 $(...)
now=$(echo today)
echo "result=$now"
nested=$(echo "$(echo inner)")
echo "nested=$nested"
