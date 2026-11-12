'use strict';
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { resolveExecutable, configuredPath } = require('./server');

function rendererFor(uri) {
    const folder = vscode.workspace.getWorkspaceFolder(uri) || vscode.workspace.workspaceFolders?.[0];
    const settings = vscode.workspace.getConfiguration('huak', uri);
    const renderer = resolveExecutable(folder?.uri.fsPath, { executablePath: settings.get('executablePath'), libtypstPath: settings.get('libtypstPath') });
    const fonts = settings.get('preview.fontPaths', []).map(directory => `--font-path=${configuredPath(directory, folder?.uri.fsPath)}`);
    if (settings.get('preview.systemFonts', false)) fonts.push('--system-fonts');
    const parameters = Object.entries(settings.get('preview.parameters', {})).map(([key, value]) => `--param=${key}=${value}`);
    return { ...renderer, args: [uri.fsPath, ...renderer.args, ...fonts, ...parameters] };
}

function renderFile(renderer, name, file, token) {
    return new Promise((resolve, reject) => {
        if (token.isCancellationRequested) return resolve(false);
        const child = spawn(renderer.command, ['run', ...renderer.args, '--output', `${name}=${file}`], {
            ...renderer.options, stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true
        });
        const cancel = token.onCancellationRequested(() => child.kill());
        let diagnostic = '';
        child.stderr.setEncoding('utf8').on('data', text => { diagnostic = (diagnostic + text).slice(-16384); });
        child.once('error', reject);
        child.once('close', (code, signal) => {
            cancel.dispose();
            if (token.isCancellationRequested) resolve(false);
            else if (code === 0) resolve(true);
            else reject(new Error(diagnostic.trim() || `Huak exited (${signal || code}).`));
        });
    });
}

async function exportPicture({ uri, picture }, renderer, token) {
    const { dir, name } = path.parse(uri.fsPath);
    const stem = picture.default ? name : `${name}.${picture.name}`;
    const choices = ['svg', 'pdf'].map(format => ({ label: format.toUpperCase(), description: `${stem}.${format}`, format }));
    const choice = await vscode.window.showQuickPick(choices, { title: 'Export Huak picture', placeHolder: 'Choose a format to save beside the source file' }, token);
    if (!choice || token.isCancellationRequested) return;
    const basename = `${stem}.${choice.format}`;
    if (path.basename(basename) !== basename) throw new Error('The output name cannot be used as a filename.');
    const destination = vscode.Uri.file(path.join(dir, basename));
    if (destination.fsPath === uri.fsPath) throw new Error('An export cannot replace its source file.');
    let overwrite = false;
    try {
        const existing = await fs.stat(destination.fsPath, { bigint: true });
        if (existing.isDirectory()) throw new Error(`'${basename}' is a directory.`);
        const source = await fs.stat(uri.fsPath, { bigint: true });
        if (existing.dev === source.dev && existing.ino === source.ino) throw new Error('An export cannot replace its source file.');
        overwrite = await vscode.window.showWarningMessage(`Replace '${basename}'?`, { modal: true }, 'Replace') === 'Replace';
        if (!overwrite) return;
    } catch (error) {
        if (error.code !== 'ENOENT') throw error;
    }

    return vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: `Exporting ${basename}` }, async () => {
        const staging = await fs.mkdtemp(path.join(dir, '.huak-export-'));
        try {
            const file = path.join(staging, basename);
            if (!await renderFile(renderer, picture.name, file, token)) return;
            await vscode.workspace.fs.rename(vscode.Uri.file(file), destination, { overwrite });
        } finally {
            await fs.rm(staging, { recursive: true, force: true });
        }
        vscode.window.setStatusBarMessage(`Huak: exported ${destination.fsPath}`, 5000);
        return destination;
    });
}

module.exports = { rendererFor, exportPicture };
