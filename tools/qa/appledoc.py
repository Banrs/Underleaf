#!/usr/bin/env python3
import json, sys, subprocess, urllib.parse

def fetch(path):
    path = path.replace('https://developer.apple.com/', '').strip('/')
    url = 'https://developer.apple.com/tutorials/data/' + urllib.parse.quote(path.lower(), safe='/():_-.') + '.json'
    r = subprocess.run(['curl', '-sS', '-f', '-m', '30', '-A', 'Mozilla/5.0', url], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr.strip() or 'curl failed')
    return json.loads(r.stdout)

def inline(nodes, refs):
    out = []
    for n in nodes or []:
        t = n.get('type')
        if t == 'text': out.append(n.get('text', ''))
        elif t == 'codeVoice': out.append('`' + n.get('code', '') + '`')
        elif t in ('emphasis', 'strong', 'newTerm', 'inlineHead', 'superscript', 'subscript', 'strikethrough'):
            s = inline(n.get('inlineContent'), refs)
            out.append(('**' + s + '**') if t in ('strong', 'inlineHead') else s)
        elif t == 'reference':
            r = refs.get(n.get('identifier'), {})
            title = r.get('title') or inline(n.get('overridingTitleInlineContent'), refs) or n.get('identifier', '').split('/')[-1]
            out.append(title)
        elif t == 'link': out.append(n.get('title', n.get('destination', '')))
        elif t == 'image':
            r = refs.get(n.get('identifier'), {})
            if r.get('alt'): out.append('[image: ' + r['alt'] + ']')
    return ''.join(out)

def block(nodes, refs, depth=0):
    out = []
    for n in nodes or []:
        t = n.get('type')
        if t == 'heading': out.append('\n' + '#' * (n.get('level', 2) + 1) + ' ' + n.get('text', '') + '\n')
        elif t == 'paragraph': out.append(inline(n.get('inlineContent'), refs) + '\n')
        elif t in ('unorderedList', 'orderedList'):
            for i, item in enumerate(n.get('items', [])):
                body = block(item.get('content'), refs, depth + 1).strip()
                out.append('  ' * depth + ('- ' if t == 'unorderedList' else f'{i+1}. ') + body)
            out.append('')
        elif t == 'aside':
            out.append('> **' + (n.get('name') or n.get('style', 'Note')) + ':** ' + block(n.get('content'), refs).strip() + '\n')
        elif t == 'codeListing': out.append('```' + (n.get('syntax') or '') + '\n' + '\n'.join(n.get('code', [])) + '\n```\n')
        elif t == 'table':
            for row in n.get('rows', []):
                out.append('| ' + ' | '.join(block(c, refs).strip().replace('\n', ' ') for c in row) + ' |')
            out.append('')
        elif t == 'termList':
            for item in n.get('items', []):
                out.append('- **' + inline(item.get('term', {}).get('inlineContent'), refs) + '**: ' + block(item.get('definition', {}).get('content'), refs).strip())
            out.append('')
        elif t == 'tabNavigator':
            for tab in n.get('tabs', []):
                out.append('**' + tab.get('title', '') + '**\n' + block(tab.get('content'), refs))
        elif t == 'row':
            for col in n.get('columns', []): out.append(block(col.get('content'), refs))
        elif t in ('small',): out.append(inline(n.get('inlineContent'), refs) + '\n')
        elif t == 'links':
            for i in n.get('items', []):
                r = refs.get(i, {}); out.append('- ' + r.get('title', i) + (': ' + inline(r.get('abstract'), refs) if r.get('abstract') else ''))
            out.append('')
        elif 'content' in n: out.append(block(n['content'], refs, depth))
    return '\n'.join(out)

def render(d):
    refs = d.get('references', {})
    md = d.get('metadata', {})
    out = ['# ' + md.get('title', ''), '']
    plats = [f"{p.get('name')} {p.get('introducedAt','')}{' (deprecated ' + p['deprecatedAt'] + ')' if p.get('deprecatedAt') else ''}{' beta' if p.get('beta') else ''}" for p in md.get('platforms', []) or []]
    if plats: out += ['Availability: ' + ', '.join(plats), '']
    if d.get('abstract'): out += [inline(d['abstract'], refs), '']
    for s in d.get('primaryContentSections', []):
        k = s.get('kind')
        if k == 'declarations':
            for decl in s.get('declarations', []):
                out += ['```swift', ''.join(t.get('text', '') for t in decl.get('tokens', [])), '```', '']
        elif k == 'parameters':
            out.append('### Parameters')
            for p in s.get('parameters', []): out.append('- `' + p.get('name', '') + '`: ' + block(p.get('content'), refs).strip())
            out.append('')
        elif k == 'content': out.append(block(s.get('content'), refs))
        elif k == 'mentions': pass
        elif 'content' in s: out.append(block(s['content'], refs))
    for s in d.get('topicSections', []) or []:
        out.append('\n### ' + s.get('title', 'Topics'))
        for i in s.get('identifiers', []):
            r = refs.get(i, {})
            frag = ''.join(t.get('text', '') for t in r.get('fragments', [])) if r.get('fragments') else r.get('title', i)
            ab = inline(r.get('abstract'), refs)
            dep = ' (deprecated)' if r.get('deprecated') else ''
            out.append('- `' + frag + '`' + dep + (': ' + ab if ab else '') + '  <' + r.get('url', '') + '>')
    return '\n'.join(out)

if __name__ == '__main__':
    for p in sys.argv[1:]:
        try: print(render(fetch(p)))
        except Exception as e: print(f'!! {p}: {e}', file=sys.stderr)
