#!/usr/bin/env bash
# here-string <<< 与 heredoc <<
read -r line <<< "hello herestring"
echo "hs=$line"
read -r -d '' block <<'EOF'
a
b
EOF
echo "block=$block"
