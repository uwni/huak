# Huak

Huak 是一门独立的绘图语言，与 Typst 的关系类似于 MetaPost 与 LaTeX。在 Huak 脚本中，可以用点、曲线和方程描述图形，用 Typst 编写文字和公式，最后导出 SVG 或 PDF。

## 快速上手

你可以在 [huak.github.io](https://huak.github.io)

将下面的代码保存为 `circle.huak`。把 `r` 从 `15mm` 改为 `20mm`，圆和半径一起变大，标注仍在半径中点上方。

```huak
import paint.*

r := 15mm
default drawing picture() do
    +draw circle((0mm, 0mm), r)
    +draw (0mm, 0mm) -- (r, 0mm)
    +typ[$r$] at (r / 2, 1mm)
end
```

## 构建与运行

可以分别下载 [Huak nightly](https://github.com/uwni/huak/releases?q=huak-nightly) 和 [libtypst nightly](https://github.com/uwni/huak/releases?q=libtypst-nightly)。两个组件按各自的变更发布，标签包含对应的提交哈希。选择相同平台的压缩包（Linux x86_64 或 macOS arm64）并解压到同一目录，即可运行：

```sh
./huak run circle.huak --libtypst ./libtypst.dylib --output circle.svg
```

Linux 上将库名换为 `./libtypst.so`。

在 macOS 或 Linux 上准备 Zig 0.17.1 和 Rust 1.92，在仓库根目录构建并导出上面的图。

```sh
cargo build --locked --manifest-path libtypst/Cargo.toml
zig build
zig-out/bin/huak run circle.huak --output circle.svg --output circle.pdf
```

将 `run` 换成 `watch`，保存脚本时就会重新生成图形。[VS Code 扩展](editors/vscode/README.md) 可以直接预览 SVG。

## 本地 Playground

本地构建 Playground 需要 Rust 的 Wasm 目标。

```sh
rustup target add wasm32-wasip1
zig build playground
```

将静态 HTTP 服务器的根目录设为 `zig-out/playground/`，在浏览器打开服务地址。从 **Examples** 下拉列表选择示例即可编辑并渲染，选回 **Scratchpad** 可继续编辑原稿。构建时会自动收录 `examples/` 下的 `.huak` 脚本，`lib/` 子目录里的模块供示例导入。

## 更多示例

- [绘图脚本](examples/language/)涵盖平滑曲线、笔触和路径交织。
- [三叶结](examples/language/trefoil.huak)用 `ab & bc & ca` 把三段首尾相接的 Bézier 曲线拼成一条路径。
- [Huak 标志](examples/huak-logo.huak)用 `import regions.{union, minus}` 引入区域运算，再用 `a union b` 合并字形轮廓。需要交集或对称差时，可从同一模块导入 `inter` 或 `xor`。
- [选择性擦除](examples/language/erase.huak)对照展示点划线、异形笔尖和变宽曲线。用 `erase sweep from [curve, band] with brush` 沿路径擦除，已有闭合笔迹时可写 `erase footprint from [curve, band]`。
- [Plot 图集](packages/plot/docs/gallery.md)展示折线图、误差棒和热图，并附有源码。
- [Nodegraph](packages/nodegraph/README.md) 用节点和箭头绘制关系图。
