# Arrows for Huak

Arrows 是独立的箭头包，模型照 Typst 的 [tiptoe](https://typst.app/universe/package/tiptoe/)：箭头头（mark）是线条的属性，一次调用画出线条和它的全部 mark。它不属于 huak 标准库，huak 不内嵌它，也不在 `catalog` 里注册。

- 入口：`arrows.huak`
- 模块：`arrows/`
- 示例：`examples/`
- 验收：在本目录运行 `zig run -OReleaseSafe tests/acceptance.zig -- ../../zig-out/bin/huak ../../libtypst/target/release/libtypst.dylib`

```huak
import paint.{rgb, picture, append}
import geometry.bezier
import "arrows.huak" as arrows

pic := picture()
curve := bezier((0pt, 0pt), (30pt, 0pt), (40pt, 20pt), (60pt, 30pt))
append(pic, arrows.line(curve, pen(rgb(0.9, 0.4, 0.2), 1.3pt), tip: arrows.stealth, toe: arrows.bar))
append(pic, arrows.line((0pt, -20pt) -- (60pt, -20pt), pen(rgb(0, 0, 0), 1pt), tip: arrows.combine(arrows.stealth, arrows.stealth), marks: [arrows.along(arrows.disk)]))
default pic
```

包里有 `disk`、`square` 这类常见名字，建议像上例那样按名称空间导入，或只选用到的几个。`paint.*` 已导出 `circle`，所以 tiptoe 的 `circle` 在这里叫 `disk`。

## 一次调用

```text
line(curve, pen, tip: false, toe: false, marks: []) -> picture
```

- `tip` 画在路径终点，`toe` 画在起点并朝外，两者都取 false 或一个 mark。`marks` 放路径中途的 mark，例如 `along(stealth, 0.3)`：mark 的墨迹居中在弧长 30% 处，朝路径前进方向；要反向，用该 mark 的 `rev`。
- 没有 mark 时，`line` 就是用 `pen` 画出的原生描边。
- 有 mark 时，箭杆和所有用这支笔颜料（`pen.paint`）画的 mark 合成一条路径，按非零规则只上一次色。重叠处不会重复上色，所以不会出现缝；半透明颜料也不会在重叠处变深，渐变从箭杆连续画进箭头头。
- 箭杆的外形由 `pen.stroke_sections` 取得，虚线相位、连接和笔尖都和这支笔在整条路径上画出的一样，只是在两端 mark 的 neck 处截断。圆笔截出的是平口。扁笔尖截断处会留下笔尖的印子，所以截断点先往回退，退的距离是印子越过截断点的长度，使墨迹恰好止于 neck。中途的 mark 下面，箭杆不断开。
- 颜料与线不同的部分不并进这条路径，各自单独画：
  - 双色 mark 的填充色（例如 `fill: rgb(1,1,1)`）画在线的路径下面，就像填充在自己的轮廓下面；
  - 其余另一种颜料的部分（例如 `inked` 的 mark）画在线的路径上面。
- mark 的线宽是笔在该处垂直于路径方向的宽度，用 `penoffset` 量出：圆笔就是笔宽，扁笔尖随方向变化。
- 线条有 mark 时必须是单一子路径且长度不为零；只带中途 mark 时可以是闭合路径。

## mark 是函数

mark 是第一个参数为 `line:Line` 的函数，其余参数都有默认值，用 `.with(...)` 设置：`stealth.with(inset: 0.2)`、`disk.with(fill: false)`。`Line` 有两个字段：`paint` 和 `thickness`。mark 返回 `Mark`：

| 字段 | 含义 |
|---|---|
| `pieces` | 尖端坐标下的墨迹，每块是一个 `Piece`：一条路径加上填充和描边用的颜料（不画的取 false）、描边宽度、线帽、连接。尖端在原点，线从 -x 方向进来 |
| `back` | 下一个 mark 从尖端往回多远接上，即 tiptoe 的 `end` |
| `neck` | 箭杆从尖端往回多远起被盖住；这一点落在 mark 的墨迹里 |
| `bend` | true 时 mark 随曲线弯曲（`transform.bent`），false 时保持形状 |

`line` 把每块路径映射到曲线上，再在那里上色。自定义 mark 遵守同样的约定即可，`line` 不区分预定义的和自定义的。`glyph(mark)` 在尖端坐标下单独画出一个 mark。

## 预定义 mark

尺寸和 tiptoe 一样，是固定部分加若干倍线宽（下表 t 为线宽）。

- 尺寸参数取 false 时用默认值，给长度则用该长度。
- `fill` 取 true 时用线的颜料填充，取 false 时只画轮廓，给颜料则用它填充、再用线的颜料描边。三种画法下 mark 的外形尺寸相同。

| mark | 参数（默认） |
|---|---|
| `stealth` | `length` 3pt+4.5t，`width` 0.8·length，`inset` 0.4，`fill`，`rev` |
| `triangle` | 同 stealth，没有凹口 |
| `round` | 同 stealth，转角为圆角 |
| `straight` | `length`、`width`、`rev`：开口箭头 |
| `barb`、`hooks` | `width` 3pt+4.5t，`sweep` 180deg，`rev` |
| `tikz` | `width` 3pt+4.5t：TikZ `to` 的弯钩 |
| `bar` | `width` 2.4pt+3.6t，`align` "center" 或 "end" |
| `bracket` | `width` 2.4pt+3.6t，`length` 0.3·width，`rev` |
| `disk`、`square` | `length` 4t，`width` = length，`fill`，`align` |
| `diamond` | `length` 4√2·t，`width` = length，`fill`，`align` |
| `rays` | `count` 4，`length` 2.8t，`phase`，`align` |

`disk`、`square`、`diamond`、`rays` 居中在端点上，放置时不弯曲。

组合子：

- `combine(a, b, …)`：每个 mark 接在前一个的 `back` 处，箭杆在最后一个 mark 的 neck 处被盖住。
- `gap(distance)`：combine 里的间隔。
- `rigid(mark)`：不弯曲，沿 neck 到尖端的弦摆正。
- `inked(mark, paint)`：mark 改用另一种颜料，线宽不变。

## 接合

- mark 和箭杆用路径的同一套弧长参数定位。弯曲的 mark 由 `transform.bent` 放置，轴线就是路径本身；箭杆在 neck 处按弧长截断，端面与路径垂直，落在 mark 的轴上。
- neck 落在墨迹内部：实心头取凹口与“头部宽度等于箭杆宽度”之处的中点，描边的 mark 取轮廓线。所以箭杆不会从尖端或两侧露出来，也不会进入空心 mark 的内部。
- 合并路径里每块外形的绕向都是逆时针：描边外形由 `stroke_sections` 规范化，填充块按控制点算出的有向面积确定方向，必要时反转。这样重叠的各块按非零规则相加，不会互相抵消成洞。

`tests/joins.huak` 在直线、曲线和圆弧上，用三种线宽逐个检查每种 mark 的最终墨迹区域：

- 箭杆端面在 mark 之内；
- 箭杆露在 mark 外的部分只有一块；
- 箭杆不会多出独立的一块。

`tests/acceptance.zig` 另外用 Poppler 把 PDF 光栅化，沿每支箭头的轴线检查三件事：

- 实心箭头从箭杆到头部一直是深色；
- 渐变箭头的灰度从箭杆连续过渡到头部，没有跳变；
- 50% 透明的箭头全程灰度一致。

每项检查各配一条对照行，按会失败的方式来画：

- 箭杆与箭头头边对边相接；
- 箭头头用平移过的渐变上色；
- 箭杆与箭头头是两个半透明对象。

对照行证明这三种缺陷确实会在光栅图上显出来，检查能把它们找出来。
