"""Conservative validation for faithful dictation edits, with Unicode tokens.

The model proposes edits. This module only accepts or rejects them; it never
answers dictation or generates replacement wording. Ambiguity falls back to the
original. Explicit correction alternatives are intentionally narrow.
"""
import re

_WORD = re.compile(r"\d+(?:[.,:/-]\d+)*|[^\W\d]\w*(?:['’]\w+)*", re.UNICODE)
_NUMBER = r"[$€£]?[-+]?\d+(?:[.,:/-]\d+)*%?"
_FILLERS = {'um', 'uh', 'erm', 'hmm'}
_STUTTERS = {'the', 'a', 'an', 'to', 'of', 'and', 'i'}


def _tokens(text):
    text = re.sub(r'^\s*\d+[.)]\s+', '', text, flags=re.M)
    return [word.casefold().replace('’', "'") for word in _WORD.findall(text)]


def _clean_fillers(words):
    result = []
    for word in words:
        if word in _FILLERS: continue
        if result and word == result[-1] and word in _STUTTERS: continue
        result.append(word)
    if len(result) >= 6 and result[-2:] == ['you', 'know'] and not set(result[:-2]) & {'say', 'word', 'words', 'phrase', 'title', 'called', 'write', 'keep'}:
        result = result[:-2]
    return result


def _correction_alternative(text):
    # Only adjacent replacements of the same explicitly spoken numeric slot.
    text = re.sub(rf'({_NUMBER})\s*,?\s*(?:sorry\s*,?|actually\s*,?|make that)\s*({_NUMBER})(?!\w)',
                  lambda m: m[2], text, flags=re.I)
    # A repeated preposition makes the recipient correction explicit.
    text = re.sub(r'\b(to|for|with)\s+[A-Z][\w’\'-]*\s*,?\s*(?:sorry|I mean)\s*,?\s*\1\s+([A-Z][\w’\'-]*)',
                  lambda m: m[1] + ' ' + m[2], text)
    def corrected_clause(match):
        before, after = match[1].strip(), match[2].strip()
        def signature(value):
            ignored = {'do', 'does', 'did', 'not', 'no', 'never'}
            return [word.removesuffix('ed').removesuffix('e') for word in _tokens(value) if word not in ignored]
        left, right = _tokens(before), _tokens(after)
        if left and right and left[0] == right[0] and left[0] in {'i', 'we', 'you', 'he', 'she', 'they'} and len(signature(before)) >= 3 and signature(before) == signature(after):
            return after + match[3]
        return match[0]
    return re.sub(r'([^.!?\n]+),\s*no,?\s*([^.!?\n]+)([.!?]|$)', corrected_clause, text, flags=re.I)


def _list_alternatives(source, output):
    labels = re.findall(r'^\s*(\d+)[.)]\s+', output, re.M)
    if len(labels) < 2 or labels != [str(i + 1) for i in range(len(labels))]: return []
    # A formatting-only list may remove its sequence markers, but cannot reorder
    # or omit the actual item words. Ordinary "first of all" is not a list.
    match = re.search(r'\bfirst\s+(?!of\s+all\b)(.+)', source, re.I | re.S)
    if not match: return []
    parts = re.split(r'\s+(?:and\s+)?then\s+', match[1], flags=re.I)
    if len(parts) != len(labels): return []
    tail = ' '.join(parts)
    prefix = source[:match.start()].strip(' ,:')
    alternatives = [prefix + ' ' + tail]
    announced = re.search(r'\b(two|three|four|five|[2-5])\s+(?:tasks|steps|things|items)\s*[:,.]?$', prefix, re.I)
    if not prefix or (announced and {'two':2,'three':3,'four':4,'five':5}.get(announced[1].lower(), int(announced[1]) if announced[1].isdigit() else 0) == len(labels)):
        alternatives.append(tail)
    return alternatives


def faithful_cleanup(source, output):
    """True only for preserved wording or explicitly allowed deletion/structure."""
    if not output.strip(): return False
    # Quoted code, flags, paths/identifiers and mixed-case technical names are
    # opaque. The model must not silently alter their spelling or syntax.
    atoms = re.findall(r'`[^`]+`|\b\w+_\w+\b|\b[A-Za-z_]\w*\.[A-Za-z]\w*\b|--[\w-]+|\b[a-zA-Z]*[a-z][A-Z]\w*\b', source)
    if any(atom not in output for atom in atoms): return False
    # Do not add Markdown wrappers to a standalone command containing flags.
    if '\n' not in source and re.match(r'^[\w./-]+\s+.+\s--[\w-]+', source):
        return source.strip() == output.strip()
    candidates = [source, _correction_alternative(source)]
    candidates += _list_alternatives(source, output)
    actual = _tokens(output)
    for candidate in candidates:
        if actual not in [_tokens(candidate), _clean_fillers(_tokens(candidate))]: continue
        # Tokenization ignores punctuation; numbers, signs, currencies and units
        # must still retain their exact written form (except list labels).
        numeric = lambda s: re.findall(_NUMBER, re.sub(r'^\s*\d+[.)]\s+', '', s, flags=re.M))
        if numeric(candidate) == numeric(output): return True
    return False
