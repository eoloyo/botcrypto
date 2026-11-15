d = {}
for k in ["b", "a", "b", "c"]:
    d.setdefault(k, []).append(len(d))
print(d)
s = "simpl-open"
print(s[::-3], s.split("-", 1)[1][1:3], sorted(set(s))[:3])
