#!/usr/bin/env python3
"""Expands a Hunspell .dic/.aff pair (single-character flags, as en_US uses) into a plain,
sorted word list for the app's desktop/web spell checker.

Usage: scripts/build-wordlist.py /usr/share/hunspell/en_US > app/assets/spelling/en_US.txt
"""
import re
import sys

base = sys.argv[1]
rules = {}  # flag -> (kind, cross, [(strip, add, cond)])
with open(base + '.aff', encoding='utf-8') as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 4 and parts[0] in ('PFX', 'SFX'):
            kind, flag = parts[0], parts[1]
            if flag not in rules:
                rules[flag] = (kind, parts[2] == 'Y', [])
            else:
                strip = '' if parts[2] == '0' else parts[2]
                add = '' if parts[3] == '0' else parts[3].split('/')[0]
                cond = parts[4] if len(parts) > 4 else '.'
                pattern = re.compile((cond + '$') if kind == 'SFX' else ('^' + cond))
                rules[flag][2].append((strip, add, pattern))


def apply(word, flag):
    kind, cross, entries = rules[flag]
    out = []
    for strip, add, pattern in entries:
        if not pattern.search(word):
            continue
        if kind == 'SFX':
            if strip and not word.endswith(strip):
                continue
            out.append(word[: len(word) - len(strip)] + add)
        else:
            if strip and not word.startswith(strip):
                continue
            out.append(add + word[len(strip):])
    return out


words = set()
with open(base + '.dic', encoding='utf-8') as f:
    next(f)  # the count
    for line in f:
        line = line.strip()
        if not line:
            continue
        word, _, flags = line.partition('/')
        flags = flags.split()[0] if flags else ''
        words.add(word)
        sfx = [fl for fl in flags if fl in rules and rules[fl][0] == 'SFX']
        pfx = [fl for fl in flags if fl in rules and rules[fl][0] == 'PFX']
        suffixed = []
        for fl in sfx:
            suffixed += [(w, rules[fl][1]) for w in apply(word, fl)]
        words.update(w for w, _ in suffixed)
        for fl in pfx:
            words.update(apply(word, fl))
            if rules[fl][1]:
                words.update(p for w, cross in suffixed if cross for p in apply(w, fl))

# Letters and apostrophes only: digits and ordinals are never flagged anyway.
for w in sorted(w for w in words if re.fullmatch(r"[A-Za-z][A-Za-z']*", w)):
    print(w)
