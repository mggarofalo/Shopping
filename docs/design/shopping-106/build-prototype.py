"""Build standalone SVG design studies from the preserved simulator captures."""
from pathlib import Path
import base64
from html import escape
ROOT = Path(__file__).resolve().parent
GREEN = '#195B45'
SECONDARY = '#626266'

def text(x, y, value, size=17, color='#111111', weight=400):
    return f'<text x="{x}" y="{y}" fill="{color}" font-size="{size}" font-weight="{weight}">{escape(value)}</text>'

def icon(kind, x, y):
    if kind == 'person':
        return f'<g transform="translate({x} {y})" fill="none" stroke="{SECONDARY}" stroke-width="1.3"><circle cx="6" cy="4" r="3"/><path d="M0 15v-2c0-5 12-5 12 0v2Z"/></g>'
    if kind == 'lock':
        return f'<g transform="translate({x} {y})" fill="{SECONDARY}"><rect x="1" y="7" width="9" height="8" rx="1.5"/><path d="M3 7V4a3 3 0 0 1 6 0v3" fill="none" stroke="{SECONDARY}" stroke-width="1.5"/></g>'
    if kind == 'check':
        return f'<g transform="translate({x} {y})" fill="none" stroke="{SECONDARY}" stroke-width="1.3"><circle cx="7" cy="8" r="6.5"/><path d="m3 8 3 3 5-7"/></g>'
    return ''

def build(name, store=False, large=False):
    background=base64.b64encode((ROOT/('baseline-costco.png' if store else 'baseline-person-note.png')).read_bytes()).decode()
    out=[f'<svg xmlns="http://www.w3.org/2000/svg" width="1206" height="2622" viewBox="0 0 402 874" role="img" aria-labelledby="title desc"><title id="title">Proposed compact Groceries, {"Costco" if store else "All stores"}{", enlarged text study" if large else ""}</title><desc id="desc">Review mockup, not an app screenshot. Category grouping, urgency, notes, person and quantity controls remain visible.</desc><defs><clipPath id="list"><rect y="232" width="402" height="557"/></clipPath><clipPath id="bottom"><rect y="789" width="402" height="85"/></clipPath></defs><image width="402" height="874" href="data:image/png;base64,{background}"/><image width="402" height="874" clip-path="url(#bottom)" href="data:image/png;base64,{base64.b64encode((ROOT/'baseline-costco.png').read_bytes()).decode()}"/><rect x="0" y="175" width="402" height="3" fill="white"/><rect x="0" y="227" width="402" height="3" fill="white"/><g font-family="-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif" clip-path="url(#list)"><rect y="176" width="402" height="613" fill="white"/>']
    y=232
    def header(label):
        nonlocal y
        out.append(text(16,y+21,label,19 if large else 13,SECONDARY,600))
        y+=36 if large else 28
    def row(title,qty=None,urgent=False,person=None,note=None,once=False,rule=None,separator=False):
        nonlocal y, out
        scale=1.5 if large else 1
        metadata=[]
        if once: metadata.append(('once','One-time'))
        if person: metadata.append(('person',person))
        if note: metadata.append(('note',note))
        h=max(48,13+21*scale+len(metadata)*(16*scale+2))
        if large and qty is not None: h+=48
        title_y=y+6+17*scale if metadata else y+(h/2)+6*scale
        out.append(text(16,title_y,title,17*scale))
        if urgent:
            # Approximate text width for the native system font at this study's size.
            xpos=16+(58 if title=='Granola' else 132)*scale+7
            out.append(f'<circle cx="{xpos+8}" cy="{title_y-6*scale}" r="{8*scale}" fill="#A93610"/>')
            out.append(text(xpos+5*scale,title_y-1*scale,'!',13*scale,'white',700))
        meta_y=title_y+18*scale
        for kind,value in metadata:
            if kind=='person': out.append(icon('person',16,meta_y-13))
            if kind=='once': out.append(text(16,meta_y,'①',14*scale,SECONDARY))
            out.append(text(36 if kind in ('person','once') else 16,meta_y,value,12*scale,SECONDARY))
            meta_y+=16*scale+2
        # Align trailing controls to the title line, even when metadata makes
        # the row taller. Centering them in the whole row drops them onto the
        # person/one-time line and makes sparse sections look misaligned.
        cy=title_y-7*scale if not large else y+h-24
        if rule: out.append(icon(rule,251 if qty else 374,cy-8))
        if qty is not None:
            # Each action occupies 44×44 points around its visual symbol.
            out += [text(293,cy+6,'−',22,'#BDBDC2' if qty==1 else GREEN),text(332,cy+6,str(qty),17,SECONDARY),text(367,cy+6,'+',24,GREEN)]
        y+=h
        if separator: out.append(f'<path d="M16 {y}H386" stroke="#E5E5E8" stroke-width="0.5"/>')
    header('Produce'); row('Bananas',qty=6,rule='check' if store else None)
    header('Pantry'); row('Granola',urgent=True,person='Michael',note='Low sugar',rule='lock' if store else None,separator=not store)
    if not store:
        row('Chipotles in adobo',separator=True); row('Local honey')
    header('Bakery'); row('Dinner rolls',rule='check' if store else None)
    if not store:
        header('Uncategorized'); row('Birthday candles',qty=1,urgent=True,once=True,note='Number candles: 4 and 0')
    out += ['</g></svg>']
    (ROOT/name).write_text(''.join(out))
    print(name, 'content bottom:',y,'pt; tab bar begins ~792 pt')
build('proposed-all.svg')
build('proposed-costco.svg',store=True)
