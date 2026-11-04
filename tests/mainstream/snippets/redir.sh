#!/usr/bin/env bash
# 重定向 > >> >&2 与 $(< file) 读回
out="zbash_redir_test.txt"
echo "first" > "$out"
echo "second" >> "$out"
echo "stderr line" >&2
content=$(< "$out")
echo "readback=$content"
rm -f "$out"
