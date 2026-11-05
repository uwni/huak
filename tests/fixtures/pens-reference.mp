% Numerical oracle only. MetaPost is not a huak build/runtime dependency.
% Run with: mpost --numbersystem=double --interaction=nonstopmode pens-reference.mp
% Recorded with MetaPost 3.00 (TeX Live 2026); expected values are retained in
% src/drawing/pen/outline.zig's reference regression test. Closed-path envelope areas
% are not compared: MetaPost's operator traces one oriented boundary, while
% huak's stroke outline includes the whole swept region and any interior hole.
vardef check(expr tag, nib, center, capvalue, joinvalue, limitvalue)=
  save e, a, u, v; path e; numeric a; pair u,v;
  interim linecap:=capvalue;
  interim linejoin:=joinvalue;
  interim miterlimit:=limitvalue;
  e:=envelope nib of center;
  a:=0;
  for i=0 upto length(e)-1:
    u:=point i of e; v:=point (i+1) of e;
    a:=a+xpart u*ypart v-ypart u*xpart v;
  endfor;
  message tag; show llcorner e; show urcorner e; show a/2;
enddef;
pen R; path L,C;
R:=pensquare xscaled 4 yscaled 2;
L:=(0,0)--(10,0);
check("rot-butt",R rotated 30,L,butt,beveled,4);
check("rot-square",R rotated 30,L,squared,beveled,4);
check("rot-round",R rotated 30,L,rounded,beveled,4);
check("shear-butt",R slanted .5,L,butt,beveled,4);
check("shear-square",R slanted .5,L,squared,beveled,4);
check("shear-round",R slanted .5,L,rounded,beveled,4);
L:=(0,0)--(-10,-5);
check("negative-butt",R,L,butt,beveled,4);
check("negative-square",R,L,squared,beveled,4);
check("negative-round",R,L,rounded,beveled,4);
C:=(0,0)--(10,0)--(10,10)--cycle;
check("closed-bevel",R,C,butt,beveled,4);
check("closed-miter",R,C,butt,mitered,4);
check("closed-round",R,C,butt,rounded,4);
check("closed-limited",R,C,butt,mitered,1);
C:=(0,0)--(10,0)--(5,3)--(10,10)--(0,10)--cycle;
check("reflex-bevel",R,C,butt,beveled,4);
check("reflex-miter",R,C,butt,mitered,4);
check("reflex-round",R,C,butt,rounded,4);
end
