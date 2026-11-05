import * as monaco from "./monaco/editor-core.mjs";
import { initShiki, initShikiMonacoTokenizer, registerShikiMonacoTokenizer, setDefaultWasmLoader } from "./monaco/shiki.mjs";
import { getWasmInstance } from "./monaco/shiki-wasm.mjs";

export async function createEditor(container, value) {
    const syntax = name => new URL(`./syntax/${name}.json`, import.meta.url);
    setDefaultWasmLoader(getWasmInstance);
    const highlighter = await initShiki({
        langs: [syntax("typst"), syntax("huak")],
        defaultTheme: syntax("light-plus"),
    });

    const style = document.createElement("style");
    style.textContent = monaco.cssBundle;
    document.head.append(style);
    globalThis.MonacoEnvironment = { getWorker: monaco.createEditorWorkerMain };
    monaco.languages.register({ id: "Huak", extensions: [".huak"] });
    initShikiMonacoTokenizer(monaco, highlighter);
    registerShikiMonacoTokenizer(monaco, highlighter, "Huak");
    return monaco.editor.create(container, {
        value, language: "Huak", theme: "light-plus", ariaLabel: "Huak source",
        automaticLayout: true, fixedOverflowWidgets: true, lineNumbers: "on", lineNumbersMinChars: 3,
        minimap: { enabled: false }, stickyScroll: { enabled: false },
        wordWrap: "on", scrollBeyondLastLine: false, padding: { top: 12, bottom: 12 },
    });
}
