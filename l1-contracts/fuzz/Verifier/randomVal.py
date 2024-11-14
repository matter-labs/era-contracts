import random
import sys
from array import array
res = [x for x in range(44)]
input = int(sys.argv[1])
res = random.sample(res, input)
out = "0x0000000000000000000000000000000000000000000000000000000000000020"
out+= f"{input:064x}"
for i in res:
    out+=f"{i:064x}"
print(out)