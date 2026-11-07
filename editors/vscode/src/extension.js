'use strict';
const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');
const { resolveServer } = require('./server');
const { Preview } = require('./preview');
let client;
let preview;
let restarting = Promise.resolve();

function restart() {
    restarting = restarting.catch(() => {}).then(async () => {
        if (client) {
            await client.stop();
            client = undefined;
        }
        const document = vscode.window.activeTextEditor?.document;
        const folder = (document && vscode.workspace.getWorkspaceFolder(document.uri)) || vscode.workspace.workspaceFolders?.[0];
        const settings = vscode.workspace.getConfiguration('huak', folder?.uri);
        const server = resolveServer(folder?.uri.fsPath, { serverPath: settings.get('serverPath'), libtypstPath: settings.get('libtypstPath') });
        client = new LanguageClient('huak', 'Huak Language Server', { ...server, transport: TransportKind.stdio }, {
            documentSelector: [{ scheme: 'file', language: 'huak' }, { scheme: 'huak-stdlib', language: 'huak' }],
            workspaceFolder: folder
        });
        await client.start();
    });
    return restarting;
}

async function activate(context) {
    async function languageClient() {
        await restarting;
        if (!client) throw new Error('The Huak language server is unavailable.');
        return client;
    }
    preview = new Preview(languageClient, context.extensionUri);
    context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('huak-stdlib', {
        async provideTextDocumentContent(uri, token) {
            const server = await languageClient();
            return server.sendRequest('huak/standardSource', { uri: uri.toString() }, token);
        }
    }));
    function command(name, action) {
        context.subscriptions.push(vscode.commands.registerCommand(name, (...args) => Promise.resolve(action(...args)).catch(error => {
            console.error(`Huak command '${name}' failed:`, error);
            if (!preview?.disposed) vscode.window.showErrorMessage(`Huak: ${error.message}`);
        })));
    }
    // editor/title supplies an editor context after the URI; webview links supply a name.
    command('huak.preview', (uri, name) => preview.open(uri, typeof name === 'string' ? name : undefined));
    command('huak.exportPicture', (uri, name) => preview.export(uri, typeof name === 'string' ? name : undefined));
    command('huak.selectPreviewOutput', uri => preview.open(uri, undefined, true));
    command('huak.stopPreview', () => preview.stop());
    context.subscriptions.push(vscode.commands.registerCommand('huak.restartLanguageServer', restart));
    context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event => {
        if (event.affectsConfiguration('huak.serverPath') || event.affectsConfiguration('huak.libtypstPath')) restart().catch(error => vscode.window.showErrorMessage(`Huak: ${error.message}`));
    }));
    await restart();
}

async function deactivate() {
    await preview?.dispose();
    preview = undefined;
    await restarting.catch(() => {});
    if (client) await client.stop();
    client = undefined;
}

module.exports = { activate, deactivate };
