'use strict';
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const readline = require('node:readline');

function parseEvent(line) {
    const value = JSON.parse(line);
    if (!value || typeof value !== 'object' || !['build_start', 'success', 'error'].includes(value.event)) throw new Error('Invalid Huak watch event');
    if (value.event === 'error' && typeof value.message !== 'string') throw new Error('Invalid Huak watch diagnostic');
    if (value.event === 'success' && (!Array.isArray(value.outputs) || !value.outputs.every(output => output && typeof output.name === 'string' && typeof output.path === 'string') || !Number.isFinite(value.duration_ms) || value.duration_ms < 0)) throw new Error('Invalid Huak watch result');
    return value;
}

class WatchProcess extends EventEmitter {
    constructor(command, args, options) {
        super();
        this.child = spawn(command, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
        this.lines = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
        this.lines.on('line', line => {
            try { this.emit('event', parseEvent(line)); }
            catch (error) { this.emit('failure', error); }
        });
        this.child.stderr.setEncoding('utf8');
        this.child.stderr.on('data', text => this.emit('log', text));
        this.child.on('error', error => this.emit('failure', error));
        this.closed = new Promise(resolve => this.child.once('close', (code, signal) => {
            this.finished = true;
            this.lines.close();
            this.emit('exit', { code, signal });
            resolve();
        }));
    }

    async stop() {
        if (this.finished) return;
        this.child.kill('SIGTERM');
        const timeout = setTimeout(() => this.child.kill('SIGKILL'), 2000);
        timeout.unref();
        try { await this.closed; }
        finally { clearTimeout(timeout); }
    }
}

module.exports = { WatchProcess, parseEvent };
