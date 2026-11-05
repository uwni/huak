'use strict';
const vscode = require('vscode');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { resolveExecutable } = require('./server');
const { WatchProcess } = require('./watch');
const { previewHtml } = require('./preview-html');
const { pictureLabel, pictureChoices } = require('./outputs');

class Preview {
    constructor(languageClient) {
        this.languageClient = languageClient;
        this.output = vscode.window.createOutputChannel('Huak Preview');
        this.transition = Promise.resolve();
        this.cancellation = new vscode.CancellationTokenSource();
    }

    enqueue(action) {
        this.transition = this.transition.catch(() => {}).then(action);
        return this.transition;
    }

    open(resource, requestedName, choose = false) {
        return this.enqueue(async () => {
            if (this.disposed) return;
            if (requestedName !== undefined && typeof requestedName !== 'string') throw new TypeError('The picture export name must be a string.');
            let uri = typeof resource === 'string' ? vscode.Uri.parse(resource) : resource?.scheme ? resource : vscode.window.activeTextEditor?.document.uri || this.session?.uri;
            if (!uri || !['file', 'untitled'].includes(uri.scheme)) throw new Error('Open or save a Huak file before rendering.');
            let document = await vscode.workspace.openTextDocument(uri);
            if (document.languageId !== 'huak') throw new Error('The selected document is not a Huak file.');
            if (document.isUntitled) {
                await vscode.window.showTextDocument(document);
                await vscode.commands.executeCommand('workbench.action.files.saveAs');
                document = vscode.window.activeTextEditor?.document;
                if (!document || document.isUntitled || document.languageId !== 'huak') return;
                uri = document.uri;
            } else if (document.isDirty && !await document.save()) return;
            const client = await this.languageClient();
            const response = await client.sendRequest('huak/outputs', { textDocument: { uri: uri.toString() } }, this.cancellation.token);
            const outputs = response.outputs;
            if (!outputs.length) throw new Error('This file has no picture outputs to preview.');
            let selected = requestedName && outputs.find(item => item.name === requestedName);
            if (requestedName && !selected) throw new Error(`Picture output '${requestedName}' is unavailable.`);
            if (!selected) selected = outputs.length === 1 ? outputs[0] : !choose ? outputs.find(item => item.default) : undefined;
            if (!selected) {
                const items = pictureChoices(outputs);
                selected = (await vscode.window.showQuickPick(items, { title: 'Choose Huak picture', placeHolder: 'Select a picture to preview' }, this.cancellation.token))?.value;
                if (!selected) return;
            }
            if (this.disposed) return;
            const previous = this.session;
            const reuse = previous && previous.uri.toString() === uri.toString() && previous.name === selected.name;
            if (reuse) {
                previous.closed = true;
                await this.stopSession(previous);
            } else await this.clearSession();
            const directory = reuse ? previous.directory : await fs.mkdtemp(path.join(os.tmpdir(), 'huak-preview-'));
            const session = this.session = { uri, name: selected.name, label: pictureLabel(selected), directory, outputPath: path.join(directory, 'render.svg'), revision: reuse && previous.revision ? previous.revision + 1 : 0, status: 'Starting render…', error: '', processing: Promise.resolve(), lastStderr: '' };
            const panel = this.panel || vscode.window.createWebviewPanel('huak.preview', 'Huak Preview', { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true }, {});
            if (!this.panel) {
                this.panel = panel;
                panel.onDidDispose(() => {
                    const closing = this.session;
                    if (this.panel === panel) this.panel = undefined;
                    this.enqueue(() => this.session === closing ? this.clearSession() : undefined).catch(error => this.output.appendLine(error.message));
                });
            }
            panel.webview.options = { enableScripts: false, enableCommandUris: ['huak.preview', 'huak.stopPreview', 'huak.selectPreviewOutput'], localResourceRoots: [vscode.Uri.file(directory)] };
            panel.title = `Huak Preview: ${session.label}`;
            panel.reveal(vscode.ViewColumn.Beside, true);
            this.update(session);
            const folder = vscode.workspace.getWorkspaceFolder(uri) || vscode.workspace.workspaceFolders?.[0];
            const settings = vscode.workspace.getConfiguration('huak', uri);
            const executable = resolveExecutable(folder?.uri.fsPath, { executablePath: settings.get('executablePath'), libtypstPath: settings.get('libtypstPath') });
            const parameters = settings.get('preview.parameters', {});
            const args = ['watch', uri.fsPath, '--json', '--output', `${selected.name}=${session.outputPath}`, ...executable.args];
            for (const [name, value] of Object.entries(parameters)) args.push(`--param=${name}=${value}`);
            const watch = session.watch = new WatchProcess(executable.command, args, executable.options);
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
        webview.html = previewHtml(webview.cspSource, { title: `${path.basename(session.uri.fsPath)} · ${session.label}`, source: session.uri.toString(), name: session.name, status: session.status, error: session.error, image });
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
