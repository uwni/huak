'use strict';
const vscode = require('vscode');

function pictureLabel(picture) {
    return picture.label || (picture.default && picture.name === 'default' ? 'Default picture' : picture.name);
}

function pictureChoices(outputs) {
    return [...outputs].sort((left, right) => Number(right.default) - Number(left.default)).map(picture => ({
        label: pictureLabel(picture),
        description: picture.default ? 'Default' : undefined,
        value: picture
    }));
}

async function selectPicture(resource, languageClient, { name, choose, token }) {
    if (name !== undefined && typeof name !== 'string') throw new TypeError('The picture output name must be a string.');
    let uri = typeof resource === 'string' ? vscode.Uri.parse(resource) : resource;
    if (!uri || !['file', 'untitled'].includes(uri.scheme)) throw new Error('Open or save a Huak file first.');
    let document = await vscode.workspace.openTextDocument(uri);
    if (document.languageId !== 'huak') throw new Error('The selected document is not a Huak file.');
    if (document.isUntitled) {
        await vscode.window.showTextDocument(document);
        await vscode.commands.executeCommand('workbench.action.files.saveAs');
        document = vscode.window.activeTextEditor?.document;
        if (!document || document.isUntitled || document.languageId !== 'huak') return;
        uri = document.uri;
    } else if (document.isDirty && !await document.save()) return;

    const client = await languageClient();
    const { outputs } = await client.sendRequest('huak/outputs', { textDocument: { uri: uri.toString() } }, token);
    if (!outputs.length) throw new Error('This file has no picture outputs.');
    let picture;
    if (name !== undefined) {
        picture = outputs.find(item => item.name === name);
        if (!picture) throw new Error(`Picture output '${name}' is unavailable.`);
    } else {
        picture = outputs.length === 1 ? outputs[0] : !choose && outputs.find(item => item.default);
        if (!picture) picture = (await vscode.window.showQuickPick(pictureChoices(outputs), { title: 'Choose Huak picture' }, token))?.value;
    }
    if (picture && !token.isCancellationRequested) return { uri, picture };
}

module.exports = { pictureLabel, pictureChoices, selectPicture };
