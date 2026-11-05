'use strict';
const fs = require('node:fs');
const path = require('node:path');

function configuredPath(value, folder) {
    if (!value) return undefined;
    const expanded = value.replaceAll('${workspaceFolder}', folder || '');
    return folder && !path.isAbsolute(expanded) ? path.resolve(folder, expanded) : expanded;
}

function executablePath(folder, configured, name, platform) {
    const executable = platform === 'win32' ? `${name}.exe` : name;
    const local = folder && path.join(folder, 'zig-out', 'bin', executable);
    return configuredPath(configured, folder) || (local && fs.existsSync(local) ? local : executable);
}

function libraryArgs(folder, settings, platform) {
    const library = platform === 'win32' ? 'typst.dll' : platform === 'darwin' ? 'libtypst.dylib' : 'libtypst.so';
    const candidates = folder ? ['debug', 'release'].map(profile => path.join(folder, 'libtypst', 'target', profile, library)) : [];
    const libtypst = configuredPath(settings.libtypstPath, folder) || candidates.find(candidate => fs.existsSync(candidate));
    return libtypst ? ['--libtypst', libtypst] : [];
}

function resolveServer(folder, settings = {}, platform = process.platform) {
    return { command: executablePath(folder, settings.serverPath, 'huak-lsp', platform), args: ['--stdio', ...libraryArgs(folder, settings, platform)], options: folder ? { cwd: folder } : undefined };
}

function resolveExecutable(folder, settings = {}, platform = process.platform) {
    return { command: executablePath(folder, settings.executablePath, 'huak', platform), args: libraryArgs(folder, settings, platform), options: folder ? { cwd: folder } : undefined };
}

module.exports = { resolveServer, resolveExecutable };
