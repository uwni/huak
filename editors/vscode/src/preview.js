'use strict';
const vscode = require('vscode');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { WatchProcess } = require('./watch');
const { previewHtml } = require('./preview-html');
const { pictureLabel, selectPicture } = require('./outputs');
const { rendererFor, exportPicture } = require('./render');

class Preview {
    constructor(languageClient, extensionUri) {
        this.languageClient = languageClient;
        this.media = vscode.Uri.joinPath(extensionUri, 'media');
        this.output = vscode.window.createOutputChannel('Huak Preview');
        this.transition = Promise.resolve();
        this.cancellation = new vscode.CancellationTokenSource();
    }

    enqueue(action) {
        this.transition = this.transition.catch(() => {}).then(action);
        return this.transition;
    }

    target(resource, name, choose) {
        const source = resource || vscode.window.activeTextEditor?.document.uri || this.session?.uri;
        return selectPicture(source, this.languageClient, { name, choose, token: this.cancellation.token });
    }

    async export(resource, name) {
        if (!resource && !vscode.window.activeTextEditor && this.session) name ??= this.session.name;
        const target = await this.target(resource, name, true);
        if (!target || this.disposed) return;
        const renderer = this.session?.uri.toString() === target.uri.toString() && this.session.name === target.picture.name
            ? this.session.renderer : rendererFor(target.uri);
        return exportPicture(target, renderer, this.cancellation.token);
    }

    open(resource, requestedName, choose = false) {
        return this.enqueue(async () => {
            if (this.disposed) return;
            const target = await this.target(resource, requestedName, choose);
            if (!target || this.disposed) return;
            const { uri, picture: selected } = target;
            const previous = this.session;
            const reuse = previous && previous.uri.toString() === uri.toString() && previous.name === selected.name;
            if (reuse) {
                previous.closed = true;
                await this.stopSession(previous);
            } else await this.clearSession();
            const directory = reuse ? previous.directory : await fs.mkdtemp(path.join(os.tmpdir(), 'huak-preview-'));
            const renderer = rendererFor(uri);
            const session = this.session = { uri, name: selected.name, label: pictureLabel(selected), renderer, directory, outputPath: path.join(directory, 'render.svg'), revision: reuse ? previous.revision : 0, status: 'Starting render…', error: '', processing: Promise.resolve(), lastStderr: '' };
            const panel = this.panel || vscode.window.createWebviewPanel('huak.preview', 'Huak Preview', { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true }, {});
            if (!this.panel) {
                this.panel = panel;
                panel.webview.onDidReceiveMessage(message => {
                    if (message === 'ready' && this.panel === panel && this.session) this.update(this.session);
                });
                panel.onDidDispose(() => {
                    const closing = this.session;
                    if (this.panel === panel) this.panel = undefined;
                    this.enqueue(() => this.session === closing ? this.clearSession() : undefined).catch(error => this.output.appendLine(error.message));
                });
            }
            panel.webview.options = { enableScripts: true, enableCommandUris: ['huak.preview', 'huak.stopPreview', 'huak.selectPreviewOutput', 'huak.exportPicture'], localResourceRoots: [vscode.Uri.file(directory), this.media] };
            panel.title = `Huak Preview: ${session.label}`;
            if (!reuse || !panel.webview.html) {
                const script = panel.webview.asWebviewUri(vscode.Uri.joinPath(this.media, 'preview.js'));
                panel.webview.html = previewHtml(panel.webview.cspSource, script.toString(), { title: `${path.basename(uri.fsPath)} · ${session.label}`, source: uri.toString(), name: session.name });
            }
            panel.reveal(vscode.ViewColumn.Beside, true);
            this.update(session);
            const args = ['watch', '--json', ...renderer.args, '--output', `${selected.name}=${session.outputPath}`];
            const watch = session.watch = new WatchProcess(renderer.command, args, renderer.options);
            watch.on('event', event => {
                session.processing = session.processing.then(() => this.event(session, event)).catch(error => this.fail(session, error.message));
            });
            watch.on('failure', error => this.fail(session, error.message));
            watch.on('log', text => {
                session.lastStderr = (session.lastStderr + text).slice(-16384);
                this.output.append(text);
            });
            watch.on('exit', result => {
                if (!session.stopping && !session.error) this.fail(session, session.lastStderr.trim() || `Huak watch exited (${result.signal || result.code}).`);
            });
            return { name: session.name, label: session.label, source: uri.toString(), directory, outputPath: session.outputPath, previewPath: session.outputPath };
        });
    }

    async event(session, event) {
        if (this.session !== session || session.closed) return;
        if (event.event === 'build_start') {
            session.status = 'Rendering…';
            session.error = '';
        } else if (event.event === 'error') {
            this.fail(session, event.message);
            return;
        } else {
            if (!event.outputs.some(output => output.name === session.name && path.resolve(output.path) === session.outputPath)) throw new Error('Huak watch did not produce the requested preview.');
            // Watch publishes this single output atomically and keeps it on a
            // failed build, so the published file is already the last good SVG.
            if (this.session !== session || session.closed) return;
            session.revision += 1;
            session.status = `Rendered in ${event.duration_ms.toFixed(1)} ms · watching saved changes`;
            session.error = '';
        }
        this.update(session);
    }

    fail(session, message) {
        if (this.session !== session || session.closed) return;
        session.status = 'Render failed · showing the last successful image';
        session.error = message;
        this.output.appendLine(message);
        this.update(session);
    }

    update(session) {
        if (!this.panel || this.session !== session || session.closed) return;
        const webview = this.panel.webview;
        const image = session.revision ? webview.asWebviewUri(vscode.Uri.file(session.outputPath)).with({ query: `revision=${session.revision}` }).toString() : undefined;
        void webview.postMessage({ image, status: session.status, error: session.error });
    }

    async stopSession(session) {
        if (!session) return;
        session.stopping = true;
        if (session.watch) await session.watch.stop();
        await session.processing;
        session.watch = undefined;
    }

    stop() {
        return this.enqueue(async () => {
            const session = this.session;
            await this.stopSession(session);
            if (session && !session.closed) {
                session.status = 'Preview stopped';
                this.update(session);
            }
        });
    }

    async clearSession() {
        const session = this.session;
        if (!session) return;
        session.closed = true;
        await this.stopSession(session);
        if (this.session === session) this.session = undefined;
        await fs.rm(session.directory, { recursive: true, force: true, maxRetries: 3 });
    }

    async dispose() {
        this.disposed = true;
        this.cancellation.cancel();
        await this.enqueue(() => this.clearSession());
        this.panel?.dispose();
        this.panel = undefined;
        this.output.dispose();
        this.cancellation.dispose();
    }
}

module.exports = { Preview };
