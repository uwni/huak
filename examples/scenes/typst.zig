pub const source =
    \\#set page(width: 290pt, height: 180pt, margin: 14pt)
    \\#set text(font: "Libertinus Serif", size: 12pt)
    \\Zig → libtypst: café, α β Ω.
    \\
    \\$ integral_0^1 x^2 dif x = 1/3 $
    \\
    \\#rect(width: 90pt, height: 22pt, fill: rgb("#68a8d8"), stroke: 0.8pt)
    \\#circle(radius: 12pt, fill: rgb("#d8a868"))
;

pub const modified_source = source ++ "\n\nIncremental label: λ = 42.\n";
