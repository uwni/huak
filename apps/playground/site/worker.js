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
self.onmessage = async ({ data: source }) => {
    try {
        const api = await (engine ??= load());
        const bytes = new TextEncoder().encode(source);
        const ptr = api.huak_input(bytes.length);
        if (!ptr) throw new Error("Out of memory");
        if (bytes.length) new Uint8Array(api.memory.buffer, ptr, bytes.length).set(bytes);
        const ok = api.huak_render();
        const result = new Uint8Array(api.memory.buffer, api.huak_result(), api.huak_result_len());
        if (ok) {
            const svg = result.slice();
            self.postMessage({ svg }, [svg.buffer]);
        } else {
            self.postMessage({ error: new TextDecoder().decode(result) });
        }
    } catch (error) {
        engine = undefined;
        self.postMessage({ error: error instanceof Error ? error.message : String(error) });
    }
};
