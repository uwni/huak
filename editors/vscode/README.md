# Huak for VS Code

Provides `.huak` syntax highlighting and connects the native `huak-lsp` server for diagnostics, completion, hover, Go to Definition, formatting and matching block labels beside `end`. Inlay labels link to the opening keyword and do not change source. VS Code's existing inlay hint preferences apply.

Use **Go to Definition** (F12) or Ctrl/Cmd-click on a user symbol to open its declaration. Navigation follows scoped imports, aliases and re-exports to their original source, including unsaved open modules. Standard-library declarations open in read-only `huak-stdlib:` documents supplied by the installed server, so navigation also works outside the Huak repository. Native functions and embedded Typst symbols have no Huak body to open; re-exporting a native function does not fabricate one.

Variables use `:=` for declaration and `=` for reassignment. Navigation and completion follow lexical function, branch, loop and drawing scopes, including local shadowing. The formatter spaces both operators; `name := value` is not a type annotation.

Struct declarations, qualified type annotations, fields and named arguments participate in navigation and hover. Field completion follows declared types, constructors and simple aliases; constructor and function calls offer named parameters. The formatter indents `struct` blocks and formats dictionary entries and named arguments while preserving Typst content. Completion includes the basic prelude and constructors, plus the default native namespaces `math`, `geometry`, `color`, `pen`, `transform`, `picture`, `text`, `animation` and `solver`. Use `math.sin(...)`, `geometry.circle(...)` or `pen.pencircle(...)` directly; select members with ordinary imports when unqualified calls are useful. Local data or namespace bindings shadow the corresponding default namespace. `paint` supplies source-defined drawing strategies and call forms.

Function call forms use `mixfix` declarations: `mixfix(f) f _ in unary` places the head first, and `mixfix(f) _ f _ in addition` adds a left operand. Mixfix labels such as `center` and `radius` remain ordinary identifiers; their meaning and diagnostics come from the same native frontend used by the CLI. The formatter preserves the declared words and parameter slots.

The name in parentheses selects the function. Everything before `in` that follows the closing parenthesis is the call template. For example, `mixfix(joined) _ & _ in concatenation` makes `a & b` call `joined(a, b)`. Importing `paint.joined as glue` gives you `glue(a, b)` and the same `a & b` syntax. Words such as `as` can appear literally in a template.

With `import object as objects`, the declaration `mixfix(objects.draw) draw _ with _ in logical_or` makes `draw curve with ink` call `objects.draw(curve, ink)`. The module name resolves where the template is declared. Use a local binding for partial application, as in `add := insert.with(target: target)` followed by `mixfix(add) + _ in insertion`.

The standard `drawing` block provides the `draw curve with ink` and `fill curve` templates. For ordinary calls such as `draw(curve, ink)` or `label(body, position)`, import the functions in the script or use their qualified `object` names.

Format Document uses the same native formatter as `huak-fmt`: assignments and comparisons receive spaces, commas are followed by one space, and nested blocks and multiline argument/list contents are indented. The editor's tab size and spaces-or-tabs setting are respected. Strings, comments and embedded Typst stay unchanged; the distinction between `foo(...)` and the spaced prefix form `foo (...)` is preserved.

TextMate colors function declarations and adjacent calls such as `foo(...)`. The server supplies semantic overlays for mixfix declarations and calls: function heads use `function`, template words use `keyword`, argument variables use `variable`, namespace qualifiers use `namespace`, and declaration slots use `operator`. For example, the two occurrences of `center` in `circle with center center radius r` are a template word and a variable. Classification follows the shared AST, including nested calls, scoped declarations and imported aliases from unsaved open modules. Strings, comments and embedded Typst are excluded; incomplete syntax falls back to lexical colors.

Colors follow the editor theme. Enable `editor.semanticHighlighting.enabled` if the theme leaves semantic highlighting off. After updating `huak-lsp`, run **Huak: Restart Language Server**; the existing language client discovers semantic token support from the server.

Type names are highlighted in declaration annotations and function results. The same words can be ordinary values: for example, the parameter and body reference named `color` in `fn marker(color: color)` stay variable-colored, and range/slice endpoints are not mistaken for annotations.

Build the tools in the Huak repository with `zig build`. The extension finds the executables in `zig-out/bin/` and libtypst in `zig-out/lib/`. It also recognizes standalone Cargo builds. Set **Huak: Server Path**, **Huak: Executable Path** and **Huak: Libtypst Path** for another installation. Relative paths resolve against the workspace folder.

## Live preview

Use the preview button in a Huak editor's title bar, or **Huak: Render / Preview**. The extension saves the selected file before starting native `huak watch`; subsequent updates follow saved source and imported files. It does not change auto-save preferences. The default picture is selected when present; otherwise a single picture is automatic and multiple pictures use a picker. The default is marked on its named picture's row when the server proves they are the same binding; anonymous defaults appear as **Default picture**. Display labels are separate from canonical CLI selectors, so renaming a row never redirects rendering. **Huak: Choose Preview Output** changes the picture. Optional `huak.preview.parameters` supplies declared script parameters.

The preview displays the exported SVG as an image, including native SVG animation. Native watch publishes complete output files atomically and retains the last successful file on a failed build; the extension displays that file directly. Failed builds show their error while retaining that image. **Huak: Stop Preview** stops rendering and retains the image; closing the preview stops its process and removes temporary files. Restart keeps the selected picture and its last successful image. Restart the preview after changing renderer paths or parameters. Preview uses the CLI's structured JSONL events and LSP output discovery; it does not parse Huak source or watch files itself.

`typst_expose title, count` exposes selected Huak data to the local `huak` namespace in Typst. Its declaration names support ordinary Go to Definition, while Typst source stays opaque to Huak tooling. The native compiler validates the selected bindings; the extension does not mirror that logic.

Embedded `typ[…]` and `setup_typst {…}` highlighting reuses the Typst grammar supplied by Tinymist when installed. It does not parse or evaluate Typst independently.

## Installation and native verification

```sh
code --install-extension huak-0.2.7.vsix
# From the Huak repository:
zig build test-tools
```

Configure the three Huak executable/library paths through VS Code settings.
Only extension runtime JavaScript is retained. Node-based development,
packaging, settings scripts and test drivers have been removed. The existing
VSIX predates the output protocol change. The local `dist/extension.js` has been
updated with the same protocol fields as the runtime source, without Node;
a new VSIX has not been packaged. The locally installed extension runtime was
synchronized on 2026-11-04 to use `huak/outputs`; reload the VS Code window after
updating that runtime. Restarting only the language server does not reload
extension JavaScript. Reinstalling the old VSIX restores the incompatible
`huak/exports` request. `zig build test-tools` tests the native LSP
and formatter, not the VS Code extension host or TextMate grammar.

`huak/outputs` returns entries such as `{ "name": "default", "label": "chart", "default": true }`. `label` is display text; `name` always supplies the CLI selector, including webview restart commands. Older servers without `label` remain usable. If a later assignment changes a named binding, or the server cannot prove the alias, the default snapshot and named picture remain separate choices; the client never merges them by their names.
