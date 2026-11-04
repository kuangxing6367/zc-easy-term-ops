#!/usr/bin/env bash
# 算术 (( )) 与 $(( ))
a=3
b=4
echo $((a + b))
(( c = a * b ))
echo "c=$c"
i=0
while (( i < 3 )); do echo "i=$i"; ((i++)); done
