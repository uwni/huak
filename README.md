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
zig build install
zig-out/bin/huak run circle.huak --output circle.svg --output circle.pdf
```

动态库安装在 `zig-out/lib/`。单独构建它用 `zig build libtypst`。将 `run` 换成 `watch`，保存脚本时就会重新生成图形。[VS Code 扩展](editors/vscode/README.md) 可以直接预览 SVG。

PDF 的生成工具信息写作 `huak <版本> (Typst <版本>)`，同时记录在 `Creator` 和 XMP `CreatorTool` 中；Typst 版本来自实际加载的 libtypst。

## 三维投影

二维和三维路径共用 `--`、`&` 和 Bézier 构造器。用 `space` 拉伸、旋转、扫掠或放样轮廓，再将模型投影成二维路径。棱线、曲面轮廓和模型交线可分别设置线型。画半透明表面时按 `projection.layers` 从远到近填色、描边。[同一条圆弧生成曲面和实体](examples/space/profiles.huak) · [圆柱穿过透明球](examples/space/solids.huak) · [圆环与贴面螺旋](examples/space/torus.huak)

桌面版启动时自动加载三维投影库。只画二维图可以省去 OCCT。使用 nightly 时，将随包提供的 `libhuak_space` 放在 `huak` 旁边，并安装匹配的 OCCT 8.0 运行库。自行构建投影库需要 CMake 和 OCCT SDK，将 `OCCT_PREFIX` 设为 SDK 安装目录即可。[OCCT 8.0.1](https://github.com/Open-Cascade-SAS/OCCT/releases/tag/V8.0.1) · [许可证与声明](src/drawing/space/licenses/) · [三维接口与构建说明](src/drawing/space/README.md)

```sh
zig build space-backend -Docct="$OCCT_PREFIX"
zig-out/bin/huak run examples/space/torus.huak --output torus.svg --output torus.pdf
```

## 本地 Playground

本地构建 Playground 需要 Rust 的 Wasm 目标。

```sh
rustup target add wasm32-wasip1
zig build playground
```

将静态 HTTP 服务器的根目录设为 `zig-out/playground/`，在浏览器打开服务地址。从 **Examples** 下拉列表选择示例即可编辑并渲染，选回 **Scratchpad** 可继续编辑原稿。构建时会自动收录 `examples/` 下的 `.huak` 脚本，`lib/` 子目录里的模块供示例导入。

## 沿路径改变笔尖

`moving()` 中的 `t` 从 0 到 1，表示当前子路径的弧长比例。下例使用同一支笔绘制曲线和擦除指定对象。方笔的横向尺寸随 `t²` 增长，纵向尺寸减半，同时旋转 135°。

```huak
import paint.*
import pen_motion.*
import pen.pensquare

turn := moving() do
    return (scaling x (1 + t * t) y (1 - t / 2)) followed by (rotation by (135deg * t))
end
brush := pen(rgb(0.10,0.25,0.26), nib:pensquare(8pt), motion:turn, tolerance:0.01pt)
```

在 `drawing` 块内写 `+draw guide with brush` 或 `erase guide from [curve, band] with brush`。`followed by` 按书写顺序应用变换。参数可使用加减乘和常数除法，最高支持 12 次多项式。缩放要求 Bernstein 控制值非负。需要折点时可写 `rotation by [[0,0deg],[0.4,90deg],[1,30deg]]`。完整一圈可直接写 `360deg * t`。

`path_frame()` 把笔尖的局部 x 轴对准原曲线切线，y 轴对准左法线。标准库函数 `along_normal()` 先旋转 90° 再应用这个坐标系，让原本沿 x 轴的长轴始终垂直于路径。沿用上例的导入，可以这样绘制一条曲线：

```huak
turn := (scaling x 4 y 1) followed by along_normal()
ink := pen(rgb(0.2,0.4,0.7), nib:pensquare(2pt), motion:turn, tolerance:0.05pt)
guide := bezier((5pt,8pt),(18pt,30pt),(32pt,2pt),(45pt,20pt))
export page := drawing picture(50pt,32pt) do +draw guide with ink end
```

段内方向由原始 Bézier 导数求得，`tolerance` 控制输出轮廓的空间误差。`~~` 和 `smooth(...)` 构造的 Hobby 光滑接点只保存一份求解切向，包括闭合接缝。编辑一侧决定切向的控制柄后，该侧改用当前曲线的导数。移动接点会使两侧的旧切向同时失效。手写 Bézier 的接点按两侧实际切向判断，可消去的停点使用极限切向。每个子路径独立定向，整条子路径静止时无法确定方向。

在相邻路径段的尖角处，`along_normal` 和 `path_frame` 均接受 `corner` 参数：

- `along_normal(corner:"rotate")` 把笔尖中心固定在接点，沿最短转角连续扫到出射方向。恰好折返 180° 时取路径坐标系的正转角。
- `along_normal(corner:"overlap")` 取入射与出射笔迹的并集。重叠区域只着色一次，角外只在旋转途中才会经过的区域保持空白。
- 省略参数或传 `"strict"` 时，两侧有向切线不一致会报错。

两种转角处理都保留同一条路径和连续的弧长进度，转角本身不占弧长。缩放、宽度和其它按进度变化的参数在转动时保持接点值。闭合接缝使用相同的策略，仍要求其它运动在首尾给出兼容的笔尖位置。

`tolerance` 指路径坐标系里的物理长度，默认 0.001 pt。引擎按误差预算细分中心线、椭圆笔尖和运动，在每个区间内连续构造边界。绘制和擦除共用可输出至 SVG 和 PDF 的轮廓，两种格式的坐标精度按较严者检查。精度或工作量超限会报错。闭合子路径要求笔尖首尾位置在接缝预算内一致。动态笔的端部和拐角由笔尖本身形成，目前仅支持实线。

`profile:[[0,1pt],[0.5,14pt],[1,1pt]]` 是圆笔沿弧长变宽的简写，使用相同的扫掠算法。已有脚本如需横截面宽度、平头或斜接的旧几何，可显式调用 `pen.profile_outline`。[可运行的绘制与擦除示例](examples/language/erase.huak) · [几何基准](bench/README.md)

## 更多示例

- [绘图脚本](examples/language/)涵盖平滑曲线、笔触和路径交织。
- [三叶结](examples/language/trefoil.huak)用 `ab & bc & ca` 把三段首尾相接的 Bézier 曲线拼成一条路径。
- [矩阵标注](examples/language/anchors.huak)用 Typst 标签标记矩阵元素，`m.anchors["a"]` 读出 Typst 排出的位置，再在元素之间画箭头。
- [Huak 标志](examples/huak-logo.huak)用 `import regions.{union, minus}` 引入区域运算，再用 `a union b` 合并字形轮廓。需要交集或对称差时，可从同一模块导入 `inter` 或 `xor`。
- [选择性擦除](examples/language/erase.huak)对照展示点划线、异形笔尖、变宽圆笔和旋转笔尖。
- Plot 提供折线图、误差棒和热图的 [SVG 图集](packages/plot/gallery/) 和[绘图脚本](packages/plot/examples/)。
- [Nodegraph](packages/nodegraph/README.md) 用节点和箭头绘制关系图。
- [画笔包](packages/brushes/README.md) 的随机篆刻刀支持朱文与白文，可分别调节缺口大小和密度。
