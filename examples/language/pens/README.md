# 笔触示例

- `nibs.huak`：同一 Hobby 曲线使用圆、扁椭圆、方形、旋转方形和三角形笔尖；虚线表示相同的中心线。
- `caps_joins.huak`：butt/round/square 端帽，bevel/round/miter 连接，以及尖角处的斜接限制。
- `dashes.huak`：实线、长短虚线、圆点、倾斜椭圆笔尖虚线，以及相位 0/3/6 mm。

从仓库根目录运行，输出目录须已存在：

```sh
zig-out/bin/huak run examples/language/pens/nibs.huak \
  --output nibs.svg --output plate=nibs.pdf
zig-out/bin/huak run examples/language/pens/caps_joins.huak \
  --output caps-joins.svg --output plate=caps-joins.pdf
zig-out/bin/huak run examples/language/pens/dashes.huak \
  --output dashes.svg --output plate=dashes.pdf
```

三个脚本均通过实际 SVG/PDF 导出及页面预览。PDF 中的说明文字保留为可复制文本，笔画为矢量图形。
