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
    +draw ((0mm, 0mm) -- (r, 0mm))
    +typ[$r$] at (r / 2, 1mm)
end
```

## 构建与运行

在 macOS 或 Linux 上准备 Zig 0.17.1 和 Rust 1.92，在仓库根目录构建并导出上面的图。

```sh
cargo build --locked --manifest-path libtypst/Cargo.toml
zig build
zig-out/bin/huak run circle.huak --output circle.svg --output circle.pdf
```

将 `run` 换成 `watch`，保存脚本时就会重新生成图形。[VS Code 扩展](editors/vscode/README.md) 可以直接预览 SVG。

## 本地 Playground

要在浏览器里编辑示例并下载 SVG，可用 Rustup 添加 Wasm 目标，再用 Ruby 启动本地服务器。

```sh
rustup target add wasm32-wasip1
zig build playground
ruby -run -e httpd zig-out/playground -b 127.0.0.1 -p 8000
```

打开 [本地 Playground](http://127.0.0.1:8000/) 即可编辑。

## 更多示例

- [绘图脚本](examples/language/)涵盖平滑曲线、笔触和路径交织。
- [选择性擦除](examples/language/erase.huak)对照展示点划线、异形笔尖和变宽曲线。用 `erase sweep from [curve, band] with brush` 沿路径擦除，已有闭合笔迹时可写 `erase footprint from [curve, band]`。
- [Plot 图集](packages/plot/docs/gallery.md)展示折线图、误差棒和热图，并附有源码。
- [Nodegraph](packages/nodegraph/README.md) 用节点和箭头绘制关系图。
