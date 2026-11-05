# CLI 进程对比

`bench-compare` 对两个已构建的 CLI 使用相同参数，每次启动独立进程：

```sh
zig build bench-compare -Doptimize=ReleaseSafe -- ./huak-before ./huak-after cases.json > results.json
```

`cases.json` 列出负载名称、完整 CLI 参数及需比较的生成文件。例如：

```json
[
  {
    "name": "drawing",
    "args": ["run", "examples/language/drawing.huak", "--output=target/compare.svg"],
    "outputs": ["target/compare.svg"]
  }
]
```

路径相对于运行目录；无输出的负载可省略 `outputs`。每次运行前删除清单中的生成文件，运行后比较 SHA-256，避免误用旧产物。进程失败、缺少输出或产物变化都会使对比失败，子进程日志在 `target/compare-child.log`。

每项负载执行 2 轮预热和 16 轮交替顺序的配对测量。JSON 保存二进制路径和哈希、参数、原始样本、中位数与配对差值的 95% t 区间。耗时包含进程启动和退出；RSS 是子进程峰值驻留内存，不是分配器申请峰值。输出哈希检查在计时外执行。

比较时固定编译器、编译选项、输入和 libtypst，并保存这些来源记录。先将同一二进制同时作为 before/after 检查测量波动；短负载或多项比较的单个区间不能独立证明回退。工具不自动作验收结论。

## 动态笔尖

`zig build bench-pen-motion -Doptimize=ReleaseFast` 单独测量连续扫掠和轮廓布尔整理。中心线是一条横跨 100 pt 的三次 Bézier，圆笔直径按 2 → 12 → 1 pt 变化，7 × 3 pt 的矩形笔尖则按 `1 + t²` 横向缩放并旋转 2.2 rad。每个组合构造五次独立的轮廓，记录中位耗时与输出路径段数。计时从几何接口进入到返回，不含解释器、原生排版或文件输出。

局部区间内，笔尖的一条边和它的运动构成双线性映射。其雅可比行列式在参数方形内为一次式；零线映射成二次 Bézier，再升阶写入 Huak 的三次路径。相邻面上相抵的有向边先抵消，留下的候选边界一起按非零绕数整理。曲线中心线、椭圆笔尖及非线性运动各有空间误差预算。测试包含已知抛物线包络、增长圆盘公切线、整圈旋转、独立矩形包含判定与精度不足时报错。有关扫掠包络的奇异集合方法，可参阅[平面扫掠体与 Minkowski 和的代数构造](https://www.sciencedirect.com/science/article/abs/pii/S0167839622000437)。

2026-11-05 在 macOS arm64、Zig 0.17.1 ReleaseFast 上测得以下结果。全量测试结束后单独运行已构建的基准程序。

| 笔尖运动 | 几何容差 | 中位耗时 | 输出路径段数 |
| --- | ---: | ---: | ---: |
| 圆笔变宽 | 0.02 pt | 1.371 ms | 665 |
| 圆笔变宽 | 0.001 pt | 12.166 ms | 3074 |
| 矩形笔缩放并旋转 | 0.02 pt | 4.445 ms | 524 |
| 矩形笔缩放并旋转 | 0.001 pt | 225.083 ms | 2700 |

同日 ReleaseSafe 全量构建与测试完成 90/90 步，本轮实际运行 1281 项测试。CLI 验收完成 430 个子进程。用原生 libtypst 导出 `examples/language/erase.huak`，1 和 4 个 worker 生成的 SVG、PDF 分别逐字节一致。另用 100 pt 坐标、0.0000001 pt 导出容差验证 `OutputPrecisionRange`，用严重消去的缩放表达式验证 `PrecisionRange`。
