a="1 2  3"
n=0
for i in $a; do n=$((n+1)); done
echo "$n"
set -- "$a" $a
echo "$#"
v=${a#* }; echo "${v%% *}|${#a}"
