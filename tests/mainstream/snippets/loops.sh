#!/usr/bin/env bash
# 循环 for / for(( )) 
for x in a b c; do echo "item=$x"; done
sum=0
for ((i=1;i<=4;i++)); do ((sum+=i)); done
echo "sum=$sum"
