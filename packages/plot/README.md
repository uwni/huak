# Plot for Huak

Plot 是独立的二维绘图包。主要接口使用 Huak 的块、mixfix 和图层组合，几何和文字通过 Huak 引擎输出 SVG/PDF。

```huak
import "../plot.huak".*

fig := figure with width 14cm height 9cm
ax := axis of fig at (0, 0)
point := marker "circle" sized 5pt

plotting ax do
    title typ[Measurement and model]
    xlabel typ[Time $t$]
    ylabel typ[Amplitude]
    +lines x [0,1,2] y [0,1,0.6] named typ[Model]
    +scatter x [0,1,2] y [0.1,0.9,0.7] marked point named typ[Measured]
    legend "top-left"
end

default render fig
```

以上脚本放在 `examples/` 下。`in` 是 Huak 的保留词，轴构造使用 `axis of … at …`。图层构造及属性组合不加入坐标区，`+` 才执行加入；区块结束不隐式渲染。

## 图种与组成

- 折线、散点、分组／堆叠柱状、直方、误差棒、区间带／面积、箱形和热图。
- 线性／对数／分类轴、反向轴、等比例坐标、主次刻度、自定义文字／公式刻度。
- 规则网格子图、共用坐标轴、图例、色条、参考线和注记。
- 上下左右独立坐标轴、刻度重映射、轴端及折线箭头，以及带透明缺口的线性和对数断轴。
- 共用 Marker：圆、方形、菱形、四向三角形、加号、叉号、星形和自定义路径。

完整参数和数据语义见 [API 文档](docs/plot.md)；示例及真实 SVG/PDF 见 [图集](docs/gallery.md)。实际运行记录及限制见 [验证记录](docs/verification.md)。

在 `plotting` 块中，`breaks "left" over [[8,88]] gap 13pt` 省略左轴上的开区间 (8, 88)。轴线与网格直接分段绘制，8 和 88 两个端点之间恰好相隔 13pt。更多写法见 [断轴示例](examples/broken_axes.huak) 和 [四边轴示例](examples/four_sides.huak)。

## 运行与验收

在包目录运行，传入已构建的 Huak 和 libtypst：

```sh
../../target/plot-host/bin/huak run examples/basic.huak \
  --libtypst ../../libtypst/target/release/libtypst.dylib \
  --output=target/basic.svg --output=target/basic.pdf

zig run -OReleaseSafe tests/acceptance.zig -- \
  ../../target/plot-host/bin/huak ../../libtypst/target/release/libtypst.dylib
```

验收使用 Zig、`rsvg-convert` 和 Poppler 的 `pdftotext`／`pdftoppm`，不使用 Node 或 Python。包本身只需 Huak；这些工具仅用于测试。

从仓库根目录构建隔离的 ReleaseSafe 宿主：

```sh
zig build -Doptimize=ReleaseSafe \
  -Dlibtypst=libtypst/target/release/libtypst.dylib --prefix target/plot-host
```

性能基准在根目录运行：

```sh
zig build bench-plot -Doptimize=ReleaseSafe \
  -Dlibtypst=libtypst/target/release/libtypst.dylib
```

每项负载执行三次独立进程，原始记录保存在 `target/benchmark.jsonl`（相对于本包）。构图包含数据生成、VM、统计、布局和文字排版；导出包含原生场景输出及结果哈希，不包含磁盘写入。RSS 为整个子进程的峰值驻留内存。基准不修改生产执行预算、不自动降采样，也不宣称跨库速度优势。

## 目录

`plot.huak` 为入口；`plot/` 为描述模型、尺度、统计、Marker、文字与渲染模块；`examples/` 为图集；`tests/` 为数值及真实 CLI 验收；`bench/` 为独立基准。根构建中的 `bench-plot` 是显式基准目标，普通 Huak 构建不会嵌入本包。
