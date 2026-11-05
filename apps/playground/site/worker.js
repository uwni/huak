import { WASI, File, OpenFile, ConsoleStdout } from "./wasi/index.js";

async function load() {
    const wasi = new WASI([], [], [new OpenFile(new File([])),
        ConsoleStdout.lineBuffered(line => console.log(line)),
        ConsoleStdout.lineBuffered(line => console.error(line))]);
    const response = await fetch("./huak.wasm");
    if (!response.ok) throw new Error("Could not load huak.wasm");
    const { instance } = await WebAssembly.instantiateStreaming(response, {
        wasi_snapshot_preview1: wasi.wasiImport,
    });
    wasi.initialize(instance);
    return instance.exports;
}

let engine;
let files;
let filesLoaded = false;
const encoder = new TextEncoder();

function writeInput(api, length) {
    const ptr = api.huak_input(length);
    if (!ptr) throw new Error("Out of memory");
    return new Uint8Array(api.memory.buffer, ptr, length);
}

self.onmessage = async ({ data }) => {
    if (data.catalog) {
        files = new Uint8Array(data.catalog);
        filesLoaded = false;
        return;
    }
    const { id, path, source } = data;
    try {
        const api = await (engine ??= load());
        if (files && !filesLoaded) {
            writeInput(api, files.length).set(files);
            if (!api.huak_set_files()) throw new Error("Could not read repository examples.");
            filesLoaded = true;
        }
        const name = encoder.encode(path);
        const bytes = encoder.encode(source);
        const input = writeInput(api, name.length + bytes.length);
        input.set(name);
        input.set(bytes, name.length);
        const ok = api.huak_render(name.length);
        const result = new Uint8Array(api.memory.buffer, api.huak_result(), api.huak_result_len());
        if (ok) {
            const svg = result.slice();
            self.postMessage({ id, svg }, [svg.buffer]);
        } else {
            self.postMessage({ id, error: new TextDecoder().decode(result) });
        }
    } catch (error) {
        engine = undefined;
        filesLoaded = false;
        self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
    }
};
