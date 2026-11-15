set -e
f() { false; echo a; }
if f; then echo b; fi
echo c
