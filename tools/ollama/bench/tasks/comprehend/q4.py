def f(x, acc=[]):
    acc.append(x)
    return len(acc)
print(f(1), f(2), f(3, []), f(4))
fs = [lambda: i for i in range(3)]
print([g() for g in fs])
