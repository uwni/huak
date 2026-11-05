% Independent numeric evidence; not a runtime or build dependency.
% Same even-integer controls and axis-aligned square nib as precision.zig.
warningcheck:=0; prologues:=3; outputformat:="svg";
outputtemplate:="mp-precision-%c.svg";
pen N; N:=pensquare scaled 8;
path P,big,O,E;
pair shift; shift:=(10000000000000000,10000000000000000);
P:=(100,44)..controls(100,54)and(90,64)..(80,64)
 ..controls(70,64)and(60,54)..(60,44)
 ..controls(60,34)and(70,24)..(80,24)
 ..controls(90,24)and(100,34)..cycle;
big:=P shifted shift;
string out; out:="numeric-controls.csv";
write "case,index,p0x,p0y,c1x,c1y,c2x,c2y,p3x,p3y" to out;
vardef run(expr serial,center,origin,cut)=
 interim linejoin:=rounded; interim linecap:=rounded;
 O:=subpath(cut,length center+cut)of center;
 E:=(envelope N of O) shifted -origin;
 for k=0 upto length E - 1:
  save a,b,c,d; pair a,b,c,d;
  a:=point k of E; b:=postcontrol k of E;
  c:=precontrol(k+1)of E; d:=point(k+1)of E;
  write decimal serial&","&decimal k&","&decimal xpart a&","&decimal ypart a&","
    &decimal xpart b&","&decimal ypart b&","&decimal xpart c&","&decimal ypart c&","
    &decimal xpart d&","&decimal ypart d to out;
 endfor
 beginfig(serial); fill E; endfig;
enddef;
run(1,P,(0,0),0); run(2,P,(0,0),.5);
run(3,big,shift,0); run(4,big,shift,.5);
write EOF to out; end
