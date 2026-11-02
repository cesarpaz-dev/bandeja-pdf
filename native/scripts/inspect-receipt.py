#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only verification of one received document; exports a copy through XPC.
The output directory can include private document previews. Do not publish it.
"""
import argparse, hashlib, json, pathlib, subprocess
from pypdf import PdfReader
import pypdfium2 as pdfium


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--id',required=True)
    p.add_argument('--output',required=True,type=pathlib.Path)
    p.add_argument('--token',action='append',default=[])
    args=p.parse_args()
    out=args.output.resolve(); out.mkdir(parents=True,exist_ok=True,mode=0o700)
    cli=pathlib.Path.home()/'Applications/Bandeja PDF.app/Contents/Helpers/BandejaCLI'
    storage=pathlib.Path.home()/'Library/Application Support/BandejaPDF'
    def request(payload):
        r=subprocess.run([str(cli),'request'],input=json.dumps(payload),text=True,capture_output=True,timeout=185,check=True)
        value=json.loads(r.stdout)
        if not value.get('ok'): raise RuntimeError(value)
        return value
    state=request({'operation':'snapshot'})['snapshot']
    doc=next(d for d in state['inbox']+state['waiting'] if d['id']==args.id)
    asset_ids=sorted({page['assetID'] for page in doc['pages']})
    before={}
    for asset in asset_ids:
        folder=storage/'assets'/asset
        original=folder/'original.document'; content=folder/'content.pdf'
        with original.open('rb') as f: magic=f.read(8)
        before[asset]={'input_sha256':sha(original),'pdf_sha256':sha(content),'pdf_page_count':len(PdfReader(content).pages),'input_bytes':original.stat().st_size,'input_format':'PDF' if magic.startswith(b'%PDF-') else 'PostScript' if magic.startswith(b'%!PS') else 'unknown'}
    exported=out/'exportado.pdf'
    request({'operation':'export','documentIDs':[args.id],'path':str(exported)})
    reader=PdfReader(exported); pdf=pdfium.PdfDocument(exported)
    pages=[]; all_text=''
    for i,page in enumerate(reader.pages):
        text=page.extract_text() or ''; all_text+=text+'\n'
        ppage=pdf[i]; tpage=ppage.get_textpage(); alternative=tpage.get_text_range()
        rendered=ppage.render(scale=1.0); im=rendered.to_pil(); im.save(out/f'pagina-{i+1:02d}.png')
        pages.append({'index':i+1,'size_pt':[float(page.mediabox.width),float(page.mediabox.height)],'rotation':page.rotation,'pypdf_chars':len(text.strip()),'pdfium_chars':len(alternative.strip())})
        tpage.close(); rendered.close(); ppage.close()
    pdf.close()
    after={asset:sha(storage/'assets'/asset/'original.document') for asset in asset_ids}
    unchanged=all(v['input_sha256']==after[k] for k,v in before.items())
    stored_pdf_unchanged=all(v['pdf_sha256']==sha(storage/'assets'/k/'content.pdf') for k,v in before.items())
    original_copy=len(asset_ids)==1 and len(doc['pages'])==before[asset_ids[0]]['pdf_page_count'] and all(ref['assetID']==asset_ids[0] and ref['index']==i and ref['rotation']==0 for i,ref in enumerate(doc['pages']))
    result={'document_id':doc['id'],'title':doc['title'],'text_status':doc['textStatus'],'assets':before,'pages':pages,'expected_tokens':{token:token in all_text for token in args.token},'input_unchanged':unchanged,'stored_pdf_unchanged':stored_pdf_unchanged,'unmodified_export_matches_stored_pdf':sha(exported)==before[asset_ids[0]]['pdf_sha256'] if original_copy else None,'export_sha256':sha(exported)}
    (out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    assert unchanged
    assert stored_pdf_unchanged
    assert result['unmodified_export_matches_stored_pdf'] is not False
    assert all(result['expected_tokens'].values()), 'Missing expected text tokens; see result.json'
    print(json.dumps({'document_id':doc['id'],'pages':len(pages),'formats':[a['input_format'] for a in before.values()],'chars':[v['pypdf_chars'] for v in pages],'tokens_passed':all(result['expected_tokens'].values()) if args.token else None,'copy_exact':result['unmodified_export_matches_stored_pdf'],'result':str(out/'result.json')},ensure_ascii=False))

if __name__=='__main__': main()
