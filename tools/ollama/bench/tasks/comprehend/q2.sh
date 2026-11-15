x=5
(x=7; echo "$x") | cat
echo "$x"
n=0
printf '1\n2\n3\n' | while read -r l; do n=$((n+1)); done
echo "$n"
