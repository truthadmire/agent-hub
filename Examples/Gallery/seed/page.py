"""Server-rendered photo index; layout is shared with the filtered view."""
from html import escape

STYLE = """
:root { color-scheme: light dark; font: 1rem/1.6 Georgia,serif; }
body { max-width: 48rem; margin: auto; padding: 2rem clamp(1rem, 5vw, 4rem); }
h1 { font-weight: normal; font-size: clamp(2.75rem, 8vw, 5rem); margin: 0 0 .5em; }
ol { padding: 0; list-style: none; }
li { display:flex; align-items:baseline; justify-content:space-between; gap:1rem;
     border-top: 1px solid; padding: .8em 0; }
li span { font: .9rem system-ui,sans-serif; }
fieldset { border: 0; padding: 0; } legend { font-weight: bold; }
label,button { display:inline-flex; align-items:center; min-height: 3rem; }
label { margin-inline-end: .8rem; } button { padding-inline: 1rem; font: inherit; }
nav a { margin-inline-end: 1rem; }
"""


def layout(content):
    return (f'<!doctype html><html lang="en"><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>Field Notes · Photo index</title><style>{STYLE}</style>'
            f'<main><h1>Field Notes</h1>{content}</main></html>')


def entries(items):
    return "<ol>" + "".join(
        f'<li><strong>{escape(p["title"])}</strong><span>{escape(p["category"])}</span></li>'
        for p in items) + "</ol>"


def render(result, category=""):
    return layout(entries(result["items"]))
