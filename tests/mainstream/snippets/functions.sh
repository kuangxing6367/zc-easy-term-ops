#!/usr/bin/env bash
# 函数 + local + return
add() { local a=$1 b=$2; echo $((a+b)); }
echo "add=$(add 2 3)"
myfunc() { return 7; }
myfunc; echo "rc=$?"
