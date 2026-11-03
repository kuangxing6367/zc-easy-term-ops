#!/usr/bin/env bash
# 条件 [[ ]] / (( )) / case
s="hello"
if [[ "$s" == h* ]]; then echo "starts with h"; fi
x=10
if (( x > 5 )); then echo "x>5"; fi
case "$s" in
  hello) echo "matched hello" ;;
  *) echo "other" ;;
esac
