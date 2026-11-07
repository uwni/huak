'use strict';
const { randomBytes } = require('node:crypto');

function escape(value) {
    return String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
}

function previewHtml(cspSource, script, state) {
    const nonce = randomBytes(16).toString('hex');
    const command = (name, args) => escape(`command:${name}?${encodeURIComponent(JSON.stringify(args))}`);
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${escape(cspSource)}; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'">
<style nonce="${nonce}">
html,body{height:100%}body{box-sizing:border-box;margin:0;padding:16px;display:flex;flex-direction:column;gap:12px;color:var(--vscode-editor-foreground);background:var(--vscode-editor-background);font-family:var(--vscode-font-family)}
header,.zoom{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.zoom{gap:4px}h1{font-size:14px;font-weight:600;margin:0}a{color:var(--vscode-textLink-foreground)}
button,select{font:inherit;color:var(--vscode-dropdown-foreground);background:var(--vscode-dropdown-background);border:1px solid var(--vscode-dropdown-border);border-radius:3px;padding:2px 6px}button:disabled{opacity:.5}
:focus-visible{outline:1px solid var(--vscode-focusBorder);outline-offset:1px}
#status{margin:0;color:var(--vscode-descriptionForeground);font-size:12px}pre{margin:0;max-height:25vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--vscode-errorForeground);border-left:3px solid currentColor;padding:8px 12px}
#canvas{flex:1;min-height:0;min-width:0;overflow:auto}img{display:block;height:auto;background:white}#canvas.fit img{max-width:100%;max-height:100%}[hidden]{display:none!important}
</style><title>Huak Preview</title><script nonce="${nonce}" src="${escape(script)}" defer></script></head><body>
<header><h1>${escape(state.title)}</h1>
<span class="zoom" role="group" aria-label="Image zoom">
<button id="smaller" type="button" title="Zoom out" aria-label="Zoom out" disabled>−</button>
<select id="zoom" aria-label="Zoom level" disabled><option value="fit">Fit to view</option>${[25, 50, 75, 100, 150, 200, 400, 800].map(n => `<option value="${n}">${n}%</option>`).join('')}</select>
<button id="larger" type="button" title="Zoom in" aria-label="Zoom in" disabled>+</button></span>
<a href="${command('huak.exportPicture', [state.source, state.name])}">Export…</a>
<a href="${command('huak.selectPreviewOutput', [state.source])}">Choose output</a><a href="${command('huak.preview', [state.source, state.name])}">Render / Restart</a><a href="command:huak.stopPreview">Stop</a></header>
<p id="status" role="status">Starting render…</p><pre id="error" role="alert" hidden></pre>
<div id="canvas" class="fit" tabindex="0" aria-label="Picture preview"><p id="empty">No rendered image yet.</p><img id="picture" alt="${escape(state.title)}" hidden></div>
</body></html>`;
}

module.exports = { previewHtml };
