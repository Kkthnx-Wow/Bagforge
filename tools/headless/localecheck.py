import re, glob, collections, sys, os

root = sys.argv[1]
os.chdir(root)
loc = open("Core/Locales/enUS.lua", encoding="utf-8").read()
key = r'((?:[^"\\]|\\.)*)'
defs = re.findall(r'^L\["' + key + r'"\]\s*=', loc, re.M)
dup = [k for k, c in collections.Counter(defs).items() if c > 1]
print("defined", len(defs), "dups", dup)

used = set()
for f in glob.glob("**/*.lua", recursive=True):
    if "Locales" in f:
        continue
    t = open(f, encoding="utf-8").read()
    for m in re.finditer(r'\bL\["' + key + r'"\]', t):
        used.add(m.group(1))
    for m in re.finditer(r'FormatClickHint\([^,]+,\s*"' + key + r'"', t):
        used.add(m.group(1))
    for m in re.finditer(r'AddClickHintLine\([^,]+,[^,]+,\s*"' + key + r'"', t):
        used.add(m.group(1))

defset = set(defs)
missing = sorted(k for k in used if k not in defset)
print("used", len(used), "missing", len(missing))
for k in missing[:60]:
    print("  MISSING:", k)
unused = sorted(k for k in defset if k not in used)
print("defined but no literal use:", len(unused))
for k in unused[:80]:
    print("  ", k)
