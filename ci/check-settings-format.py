import re, sys
src = open('vox.lua').read()
try:
    i = src.index("Window size")
except ValueError:
    sys.exit(0)  # settings html gone/renamed: not this check's business
fmt_start = src.rindex("string.format(", 0, i)
k = fmt_start + len("string.format")
depth = 0; args = []; cur = ""; in_str = None; prev = ""
for pos in range(k, len(src)):
    c = src[pos]
    if in_str:
        cur += c
        if in_str == ']]' and prev == ']' and c == ']': in_str = None
        elif in_str in ('"', "'") and c == in_str and prev != '\\': in_str = None
        prev = c; continue
    if c in ('"', "'"): in_str = c; cur += c; prev = c; continue
    if c == '[' and prev == '[': in_str = ']]'; cur += c; prev = c; continue
    if c == '(':
        depth += 1; cur += c if depth > 1 else ''
    elif c == ')':
        depth -= 1
        if depth == 0: args.append(cur.strip()); break
        cur += c
    elif c == ',' and depth == 1: args.append(cur.strip()); cur = ""
    else: cur += c
    prev = c
fmt = args[0]
n = len(re.findall(r'%s', fmt)) - 2 * len(re.findall(r'%%s', fmt))
if n != len(args) - 1:
    print(f"settings format: {n} placeholders vs {len(args)-1} args", file=sys.stderr)
    sys.exit(1)
