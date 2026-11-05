#!/usr/bin/env python3
# Lists user-facing strings in Sources/ that have no Russian translation in Localization/ru.lproj.
# Exits with 1 when something is missing, so CI catches untranslated text.
# Usage: python3 scripts/l10n-check.py [repo root]
import re, glob, sys
root = sys.argv[1] if len(sys.argv) > 1 else '.'
ru_text = open(f'{root}/Localization/ru.lproj/Localizable.strings', encoding='utf-8').read()
ru = dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', ru_text, re.M))
def norm(k): return re.sub(r'%(\d+\$)?(lld|ld|d|@|lf|f|u|llu|s)', '%X', k.replace('%%', '%'))
ru_norm = {norm(k): k for k in ru}

CTX = r'(?:String\(localized:\s*|(?<![\w.])(?:Text|Button|Toggle|Picker|LabeledContent|Section|Label|Link|TextField|SecureField|Menu|ChipPicker|SettingsToggleRow|SettingsRow|SettingsLinkRow|SettingsFooter|PrimaryButton|GlassButton|RestoreDefaultsButton)\(\s*(?:title:\s*)?|\.help\(\s*Text\(\s*|navigationTitle\(\s*|header:\s*\{\s*Text\(\s*|footer:\s*\{\s*Text\(\s*)'
def read_literal(s, i):
    # s[i] == '"'; returns (key, end) handling \( ... ) with nesting and escapes
    assert s[i] == '"'
    j = i + 1; out = []
    while j < len(s):
        c = s[j]
        if c == '\\' and j + 1 < len(s) and s[j+1] == '(':
            depth = 1; j += 2
            while j < len(s) and depth:
                if s[j] == '(': depth += 1
                elif s[j] == ')': depth -= 1
                elif s[j] == '"':  # skip nested string literal
                    _, j = read_literal(s, j); continue
                j += 1
            out.append('%X'); continue
        if c == '\\': out.append(s[j:j+2]); j += 2; continue
        if c == '"': return ''.join(out), j + 1
        if c == '\n': return None, j
        out.append(c); j += 1
    return None, j

missing = {}
for f in glob.glob(f'{root}/Sources/**/*.swift', recursive=True):
    if '/SelfTest' in f or f.endswith('Snapshot.swift'): continue  # test and sample text is never shown to users
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(CTX, s):
        i = m.end()
        if i < len(s) and s[i] == '"' and not s.startswith('"""', i):
            key, end = read_literal(s, i)
            if not key or not re.search(r'[A-Za-z]{2}', key): continue
            if re.fullmatch(r'[a-z0-9.]+', key) and '.' in key: continue   # SF Symbols or keys with defaultValue
            if s[end:end+20].lstrip().startswith(', defaultValue:') or s[end:end+20].lstrip().startswith(',defaultValue:'): continue
            if key in ru or norm(key) in ru_norm: continue
            missing.setdefault(key, []).append(f"{f.split('Sources/Deckhand/')[1]}:{s[:i].count(chr(10))+1}")
for k, v in sorted(missing.items()):
    print(f'MISSING "{k}"  <- {v[:3]}')
print(len(missing), 'missing')
sys.exit(1 if missing else 0)
