'use strict';
const { randomBytes } = require('node:crypto');

function escape(value) {
    return String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
}

function previewHtml(cspSource, state) {
    const nonce = randomBytes(16).toString('hex');
    const command = (name, args) => escape(`command:${name}?${encodeURIComponent(JSON.stringify(args))}`);
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${escape(cspSource)}; style-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'">
<style nonce="${nonce}">
body{margin:0;padding:16px;color:var(--vscode-editor-foreground);background:var(--vscode-editor-background);font-family:var(--vscode-font-family)}
header{display:flex;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:12px}h1{font-size:14px;font-weight:600;margin:0}a{color:var(--vscode-textLink-foreground)}
.status{color:var(--vscode-descriptionForeground);font-size:12px}pre{white-space:pre-wrap;overflow-wrap:anywhere;color:var(--vscode-errorForeground);border-left:3px solid currentColor;padding:8px 12px}
.canvas{overflow:auto}img{display:block;max-width:100%;height:auto;background:white}
</style><title>Huak Preview</title></head><body>
<header><h1>${escape(state.title)}</h1><a href="${command('huak.selectPreviewOutput', [state.source])}">Choose output</a><a href="${command('huak.preview', [state.source, state.name])}">Render / Restart</a><a href="command:huak.stopPreview">Stop</a></header>
<p class="status">${escape(state.status)}</p>
${state.error ? `<pre role="alert">${escape(state.error)}</pre>` : ''}
<div class="canvas">${state.image ? `<img src="${escape(state.image)}" alt="${escape(state.title)}">` : '<p>No rendered image yet.</p>'}</div>
</body></html>`;
}

module.exports = { previewHtml };
