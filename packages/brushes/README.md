# Huak 画笔

篆刻刀先处理字口转角，可按空间波长分别调整笔画两侧，再沿最终轮廓生成小缺口，笔画内部保持实心。**朱文向内**，从原有着墨笔画上减去崩口。**白文向外**，扩大阴刻槽，再从着墨印面中挖掉整条槽，下面的纸色或图案会自然透出。

在本包的 `examples/` 目录下，以下脚本可以直接运行。

```huak
import paint.*
import math.seed
import "../brushes.huak".seal_knife

seed(146)
guide := bezier((8pt, 10pt), (24pt, 40pt), (44pt, 6pt), (64pt, 30pt))
mark := seal_knife(guide, 5pt, "zhuwen", chip_size: 0.20, density: 2.0)
export stamp := picture(72pt, 40pt)
default stamp
drawing stamp do
    +mark filled rgb(0.68, 0.14, 0.09)
end
```

## 刀路与参数

| 入口 | 输入和返回值 |
| --- | --- |
| `seal_knife(curve, width, mode, …)` | 输入开放、闭合或复合中心线及完整笔宽。刀刃用 `along_normal(corner:"rotate")` 沿路径法线定向，在转角绕刀刃中心转动。默认圆头。 |
| `seal_edge(shape, width, mode, …)` | 输入已有的闭合轮廓及参考笔宽，可用字形轮廓或自定义刀锋的 `stroke_outline`。按非零绕数合并后处理裸露边缘。 |

两种入口的 `mode` 均为 `"zhuwen"` 或 `"baiwen"`。[山川示例](examples/seals.huak) 用同一个斜刃笔尖绘出朱白两印。朱文直接填色，白文使用 `region_difference(inked_face, incised)`。

| 可选参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `cap` | `"round"` | `seal_knife` 的开路径端帽。`"butt"` 在落刀、收刀点沿当地法线平切；`"square"` 沿切向多伸出半个笔宽再平切。 |
| `cap_roundness` | `1` | 圆头的圆角半径占半笔宽的比例。0 为平切，0.5 在端面中央保留一半直边，1 为半圆。 |
| `chip_size` | 0.40 | 最大缺口开口与笔宽之比，范围 0～0.75。深度随选中轮廓等比变化。 |
| `density` | 1.25 | 每一笔宽的边缘弧长上的参考缺口数，以深度至少 1.45 原图像素的观测计。加入浅痕后，候选总数按同一批实测比例增加。重叠、折返或封孔会减少最终可见数。 |
| `imprint_mix` | 0.5 | 采用钤印轮廓分布的概率。取 0 使用石材轮廓分布，取 1 使用所选钤印分布。 |
| `imprint_source` | `"qingtian"` | 默认使用故宫馆藏逐件确认为青田石的配套钤本。显式选 `"album"` 可使用历史印谱的纸上风格，所收各印的材质未逐件确定。 |
| `corner_scale` | `1` | 按实测角平分线偏移量的倍数，在两直边成 80°～100° 的转角随机倒角。外角切去角尖，内角补入角隅。设为 0 关闭。 |
| `wander` | `0` | 等比缩放两侧的波动振幅。设为 1 使用所选频谱的原幅度。 |
| `spectrum` | `[]` | 默认读取同包 [spectrum.csv](spectrum.csv) 的朱文或白文频谱。可传多行 `[最短波长, 最长波长, 负侧 RMS, 正侧 RMS, 两侧相关系数]`。波长和均方根位移都以笔宽为单位。 |

`chip_size` 或 `density` 设为 0 可单独关闭崩口。需要“小而密”可试 `chip_size: 0.15, density: 2.5`，需要细净的刀口可将密度减至 0.4。调用方通过 `math.seed` 设置种子，固定种子、参数和调用顺序即可复现同一印迹。

[煢鴉梓行示例](examples/qiongyazixing.huak) 的印文与边框共用笔宽、崩口及双侧波动参数。`rim_radius` 控制框角中线的圆弧半径，默认 2.6 pt。`cap_roundness` 单独控制笔端。

[字形部件](examples/qiongyazixing_parts.huak) 保存十个部件各自的中心线。示例中先用 `place` 缩放、定位部件，再用 `compound` 组字。例如把牙部的放置写为 `place(parts.tooth, (-7.2475pt, 0pt), sx: 1.04)`，即可围绕接底框的竖脚加宽牙部 4%。整字宽高另由 `qiong`、`ya`、`zi`、`xing` 的 `_width`、`_height` 参数控制，1 对应部件组字后的原始尺寸。例如 `--param ya_height=0.98` 可从底框起把鴉的字高收短 2%。所有变形完成后才按 `stroke_width` 走刀。

以下调用只在一侧加入波长为 2～3 个笔宽的起伏。

```huak
mark := seal_knife(guide, 5pt, "zhuwen", wander: 1, spectrum: [[2, 3, 0.06, 0, 0]])
```

直笔、弯笔和闭合轮廓都沿原有边缘的弧长取样，再沿局部法线施加位移。近水平笔段的正侧在上，近竖直笔段的正侧在左（绘图坐标向上）。两侧分别使用各自的振幅，共用的波和独立的波按频带相关系数组合。转角以及两侧分界处的位移平滑收至零。每个频带按对数波长取样，只使用在相邻转角间容得下两个周期的波；光滑闭环按整圈周长判断。曲笔沿用同一份直笔实测频谱，其原有弧度作为位移的基线。

## 分布

画笔自动导入同包的 [distribution.csv](distribution.csv)。复制整个 `packages/brushes/` 即可使用，调用者只需导入画笔函数。

CSV 中 `width_mm` 行列出每个 0.1 mm 开口宽度区间的下界和朱、白文各自的频数。画笔按频数选区间，再在区间与观测范围的交集内均匀抽取宽度。因此较常见的细缺口出现得更多。九方青田石钤本的三阈值观测共 1,668 处，其中朱文 1,003 处、白文 665 处。宽度小于 0.5 mm 有 1,134 处，至少 1 mm 有 98 处。[朱文藏品](https://www.dpm.org.cn/collection/seal/228500.html) · [白文藏品](https://www.dpm.org.cn/collection/seal/228503.html)

生成缺口轮廓还使用四组统计参数。`grain` 给出尺寸范围、密度倍率及青田石钤本上深宽比随开口宽度的变化；`rock`、`qingtian` 和 `album` 分别描述石材表面、青田石钤本和历史印谱的峰位、两侧形状及起伏。随机种子同时控制开口、轮廓和沿边位置。[石材崩边试验图 6](https://doi.org/10.1007/s00603-010-0133-2) · [青田石「張爰」印](https://digitalarchive.npm.gov.tw/Collection/Detail/25053?dep=U)

### 转角与笔画两侧的波长谱

`corner_inner_mm` 和 `corner_outer_mm` 是原九方青田石印蛻的角尖偏移分布，按 0.05 mm 就近归档。重复定位的 130 处中，29 个内角、36 个外角有可分辨的钝化。零档合并与尖角相容的 3 处和未定的 62 处，保守地让这些抽样保留原轮廓。斜切是绘制近似，大多数钤本局部尚不足以区分斜面与圆弧。倒角的大小还受相邻边长和笔宽限制。

波长谱取自《飞鸿堂印谱》《问经堂印谱》《麋研斋印存》《二金蜨堂印谱》。按整字复核，只保留方折字框及平行横竖等有直笔依据的 27 段，涉及 4 方朱文、6 方白文。沿同一段同时追踪两个字口，剔除分隔栏、转折、弧线和造型存疑处。按笔宽归一化，分别去除二次趋势，用 Hann 窗傅里叶变换统计两侧各频带的均方位移和互谱实部。每方印等权，主阈值为红度 50，另用 35 与 65 复测。

默认频带为 1～2、2～3、3～4 个笔宽。各带只使用能覆盖上界两个周期且有离散频率落在带内的笔段，朱文分别有 12、10、5 段，白文有 15、8、3 段。更长波段缺乏跨印支持，默认省略。结果描述纸上字口，包含印泥和纸张造成的变化。[《飞鸿堂印谱》](https://id.lib.harvard.edu/aleph/008048676/catalog) · [《问经堂印谱》](https://id.lib.harvard.edu/aleph/008474563/catalog) · [《麋研斋印存》](https://id.lib.harvard.edu/aleph/008047544/catalog)

## 运行

在仓库根目录使用已构建的 Huak 和 libtypst，例如 macOS 调试库：

```sh
zig-out/bin/huak run packages/brushes/tests/seal_knife.huak --libtypst libtypst/target/debug/libtypst.dylib
zig-out/bin/huak run packages/brushes/examples/seals.huak --libtypst libtypst/target/debug/libtypst.dylib --param chip_size=0.25 --param density=2 --output=seals.svg --output=seals.pdf
```
