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
