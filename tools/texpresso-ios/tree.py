"""tree.py <TeX Live root> <out folder> [package...]

The TeX tree the iPad app bundles, read-only, from an installed TeX Live: the
runtime files of the packages named (by default PACKAGES) and everything they
depend on, with what tlmgr would have generated for just those packages
(language.dat and language.def for the formats' hyphenation, pdftex.map for the
fonts) and kpathsea's ls-R. Formats aren't in it: the app makes them into its
own container on first use, where the engine caches them.
"""
import os, shutil, sys

PACKAGES = [
    'collection-basic', 'collection-latex', 'collection-latexrecommended',
    'pgf', 'xetex', 'fontspec', 'unicode-math', 'lm', 'lm-math', 'biblatex',
    'hyphen-english', 'babel-english',
]

root, out = sys.argv[1], sys.argv[2]
wanted = sys.argv[3:] or PACKAGES

packages, name, field = {}, None, None
for line in open(os.path.join(root, 'tlpkg/texlive.tlpdb'), encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('name '):
        name = line[5:]
        packages[name] = {'depend': [], 'run': [], 'execute': []}
        field = None
    elif line.startswith(('depend ', 'execute ')):
        key, value = line.split(' ', 1)
        packages[name][key].append(value)
    elif line.startswith('runfiles'):
        field = 'run'
    elif not line.startswith(' '):
        field = None
    elif field:
        packages[name][field].append(line.split()[0])

chosen, todo = set(), list(wanted)
while todo:
    n = todo.pop()
    if n in chosen or n not in packages or n.endswith('.ARCH'):
        continue
    chosen.add(n)
    todo += packages[n]['depend']

dist = os.path.join(out, 'texmf-dist')
size = 0
for n in sorted(chosen):
    for f in packages[n]['run']:
        source = os.path.join(root, f)
        if not f.startswith('texmf-dist/') or not os.path.isfile(source):
            continue
        target = os.path.join(out, f)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(source, target)
        size += os.path.getsize(source)

# What tlmgr generates from the packages' execute lines.
languages, maps = [], []
for n in sorted(chosen):
    for e in packages[n]['execute']:
        words = e.split()
        if words[0] == 'AddHyphen':
            languages.append(dict(w.split('=', 1) for w in words[1:]))
        elif words[0] in ('addMap', 'addMixedMap', 'addKanjiMap'):
            maps.append(words[1])
config = os.path.join(dist, 'tex/generic/config')
os.makedirs(config, exist_ok=True)
with open(os.path.join(config, 'language.dat'), 'w') as dat, \
        open(os.path.join(config, 'language.def'), 'w') as dfn:
    dat.write(open(os.path.join(config, 'language.us')).read())
    dfn.write(open(os.path.join(config, 'language.us.def')).read())
    for lang in languages:
        dat.write('%s %s\n' % (lang['name'], lang['file']))
        for synonym in filter(None, lang.get('synonyms', '').split(',')):
            dat.write('=%s\n' % synonym)
        dfn.write('\\addlanguage{%s}{%s}{}{%s}{%s}\n' % (
            lang['name'], lang['file'], lang['lefthyphenmin'], lang['righthyphenmin']))
found = {}
for d, _, files in os.walk(os.path.join(dist, 'fonts/map')):
    for f in files:
        found.setdefault(f, os.path.join(d, f))
mapdir = os.path.join(dist, 'fonts/map/pdftex/updmap')
os.makedirs(mapdir, exist_ok=True)
with open(os.path.join(mapdir, 'pdftex.map'), 'w') as pdftex:
    for m in maps:
        if m in found:
            pdftex.write(open(found[m], encoding='latin-1').read())
for m in ('kanjix.map', 'ckx.map'):
    open(os.path.join(mapdir, m), 'w').close()

# kpathsea's file list.
with open(os.path.join(dist, 'ls-R'), 'w') as lsr:
    lsr.write('% ls-R -- filename database for kpathsea; do not change this line.\n')
    for d, dirs, files in sorted(os.walk(dist)):
        dirs.sort()
        rel = os.path.relpath(d, dist)
        lsr.write('\n%s:\n' % ('./' if rel == '.' else './' + rel))
        for f in sorted(dirs + files):
            lsr.write(f + '\n')
shutil.copy2(os.path.join(root, 'texmf.cnf'), os.path.join(out, 'texmf.cnf'))

total = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(out) for f in fs)
print('%d packages, %.0f MB in %s' % (len(chosen), total / 1e6, out))
