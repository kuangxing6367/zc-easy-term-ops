#!/usr/bin/env bash
# 数组
declare -a arr=(one two three)
echo "second=${arr[1]}"
echo "count=${#arr[@]}"
arr[3]="four"
echo "all=${arr[*]}"
