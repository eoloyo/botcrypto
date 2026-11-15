print(round(2.5), round(3.5), 0.1 + 0.2 == 0.3, int("0x1f", 16), 7 // -2, -7 % 3)
a = [1, 2, 3]
b = a
a += [4]
c = a
a = a + [5]
print(len(b), len(c), len(a), b is c)
