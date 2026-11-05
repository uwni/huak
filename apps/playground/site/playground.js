const render = document.querySelector("#render");
const preview = document.querySelector("#preview");
const download = document.querySelector("#download");
const status = document.querySelector("#status");
const worker = new Worker("./worker.js", { type: "module" });
let url;
let editor;

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
    worker.postMessage(editor.getValue());
}

worker.onmessage = ({ data }) => {
    render.disabled = false;
    status.textContent = data.error ?? "";
    if (!data.svg) return;
    url = URL.createObjectURL(new Blob([data.svg], { type: "image/svg+xml" }));
    preview.src = download.href = url;
    preview.hidden = download.hidden = false;
};
worker.onerror = event => { status.textContent = event.message || "Could not start the rendering worker."; };
render.onclick = run;
try {
    const [response, { createEditor }] = await Promise.all([fetch("./integral.huak"), import("./editor.js")]);
    if (!response.ok) throw new Error("Could not load the example.");
    editor = await createEditor(document.querySelector("#source"), await response.text());
    run();
} catch (error) {
    status.textContent = error.message;
}
