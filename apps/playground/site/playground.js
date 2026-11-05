const render = document.querySelector("#render");
const preview = document.querySelector("#preview");
const download = document.querySelector("#download");
const status = document.querySelector("#status");
const example = document.querySelector("#example");
const worker = new Worker("./worker.js", { type: "module" });
let url;
let editor;
let active = "";
let request = 0;
const drafts = new Map();

function clearPreview() {
    if (url) URL.revokeObjectURL(url);
    url = undefined;
    preview.removeAttribute("src");
    download.removeAttribute("href");
    preview.hidden = download.hidden = true;
}

function run() {
    clearPreview();
    render.disabled = true;
    status.textContent = "Rendering…";
    worker.postMessage({ id: ++request, path: active, source: editor.getValue() });
}

worker.onmessage = ({ data }) => {
    if (data.id !== request) return;
    render.disabled = false;
    status.textContent = data.error ?? "";
    if (!data.svg) return;
    url = URL.createObjectURL(new Blob([data.svg], { type: "image/svg+xml" }));
    preview.src = download.href = url;
    preview.hidden = download.hidden = false;
};
worker.onerror = event => { status.textContent = event.message || "Could not start the rendering worker."; };
render.onclick = run;

async function loadExamples() {
    const response = await fetch("./examples.json");
    if (!response.ok) throw new Error("Could not load repository examples.");
    const bytes = await response.arrayBuffer();
    const { entries, files } = JSON.parse(new TextDecoder().decode(bytes));
    for (const path of entries) example.add(new Option(path, path));
    worker.postMessage({ catalog: bytes }, [bytes]);

    example.onchange = () => {
        drafts.set(active, editor.getValue());
        active = example.value;
        editor.setValue(drafts.get(active) ?? files[active]);
        editor.setScrollTop(0);
        run();
    };
    example.disabled = false;
}
try {
    const [response, { createEditor }] = await Promise.all([fetch("./integral.huak"), import("./editor.js")]);
    if (!response.ok) throw new Error("Could not load the example.");
    editor = await createEditor(document.querySelector("#source"), await response.text());
    run();
    loadExamples().catch(error => { example.options[0].text = error.message; });
} catch (error) {
    status.textContent = error.message;
}
