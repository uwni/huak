'use strict';
const vscode = acquireVsCodeApi();
const canvas = document.getElementById('canvas');
const image = document.getElementById('picture');
const zoom = document.getElementById('zoom');
const smaller = document.getElementById('smaller');
const larger = document.getElementById('larger');
const levels = Array.from(zoom.options).slice(1).map(option => Number(option.value));
const saved = vscode.getState()?.zoom;
if (levels.includes(Number(saved))) zoom.value = saved;

function scale() {
    return zoom.value === 'fit' ? image.getBoundingClientRect().width / image.naturalWidth * 100 : Number(zoom.value);
}

function applyZoom() {
    const fit = zoom.value === 'fit';
    canvas.classList.toggle('fit', fit);
    image.style.width = fit ? '' : `${image.naturalWidth * Number(zoom.value) / 100}px`;
    zoom.disabled = !image.naturalWidth;
    smaller.disabled = zoom.disabled || scale() <= levels[0];
    larger.disabled = zoom.disabled || scale() >= levels[levels.length - 1];
}

function setZoom(value, pointer) {
    const before = image.getBoundingClientRect();
    const viewport = canvas.getBoundingClientRect();
    const x = pointer?.clientX ?? viewport.left + canvas.clientWidth / 2;
    const y = pointer?.clientY ?? viewport.top + canvas.clientHeight / 2;
    zoom.value = value;
    applyZoom();
    if (value === 'fit') canvas.scrollTo(0, 0);
    else if (before.width && before.height) {
        const after = image.getBoundingClientRect();
        canvas.scrollBy(after.left + (x - before.left) * after.width / before.width - x,
            after.top + (y - before.top) * after.height / before.height - y);
    }
    vscode.setState({ zoom: value });
}

function step(enlarge, pointer) {
    const current = scale();
    const next = enlarge ? levels.find(n => n > current) : levels.findLast(n => n < current);
    if (next !== undefined) setZoom(String(next), pointer);
}

zoom.addEventListener('change', () => setZoom(zoom.value));
smaller.addEventListener('click', () => step(false));
larger.addEventListener('click', () => step(true));
canvas.addEventListener('wheel', event => {
    if (!(event.ctrlKey || event.metaKey) || !event.deltaY || zoom.disabled) return;
    event.preventDefault();
    step(event.deltaY < 0, event);
}, { passive: false });
image.addEventListener('load', applyZoom);
new ResizeObserver(() => { if (zoom.value === 'fit') applyZoom(); }).observe(canvas);

window.addEventListener('message', ({ data }) => {
    document.getElementById('status').textContent = data.status;
    const error = document.getElementById('error');
    error.textContent = data.error;
    error.hidden = !data.error;
    document.getElementById('empty').hidden = Boolean(data.image);
    image.hidden = !data.image;
    if (data.image && image.getAttribute('src') !== data.image) image.src = data.image;
});
vscode.postMessage('ready');
