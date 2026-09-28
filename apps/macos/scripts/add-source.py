#!/usr/bin/env python3
# add-source.py app|tests Name.swift: registers a new Swift file, already in
# TeXLocal/ or TeXLocalTests/, with its target in the committed project,
# copying an existing file's four entries (build file, file reference, group
# child, sources phase). XcodeGen, when installed, finds new files itself
# (project.yml takes the folders whole).
import os, re, secrets, sys
target, name = sys.argv[1], sys.argv[2]
p=os.path.join(os.path.dirname(__file__), '..', 'TeXLocal.xcodeproj', 'project.pbxproj')
s=open(p).read()
model = 'SyncTeXGeometry.swift' if target=='app' else 'TeXLocalTests.swift'
if f'/* {name} */' in s: sys.exit(f'{name} already registered')
build, ref = secrets.token_hex(12).upper(), secrets.token_hex(12).upper()
lines=s.split('\n'); out=[]
for line in lines:
    out.append(line)
    if f'/* {model} in Sources */ = {{isa = PBXBuildFile' in line:
        out.append(re.sub(r'^\t\t\w+', '\t\t'+build, re.sub(r'fileRef = \w+', 'fileRef = '+ref, line)).replace(model, name))
    elif f'/* {model} */ = {{isa = PBXFileReference' in line:
        out.append(re.sub(r'^\t\t\w+', '\t\t'+ref, line).replace(model, name))
    elif re.match(rf'^\t\t\t\t\w+ /\* {re.escape(model)} \*/,$', line):
        out.append(f'\t\t\t\t{ref} /* {name} */,')
    elif re.match(rf'^\t\t\t\t\w+ /\* {re.escape(model)} in Sources \*/,$', line):
        out.append(f'\t\t\t\t{build} /* {name} in Sources */,')
assert len(out)==len(lines)+4, len(out)-len(lines)
open(p,'w').write('\n'.join(out))
print('registered', name, 'in', target)
