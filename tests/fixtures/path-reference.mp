% Independent MetaPost 3.00 DOUBLE oracle for mixed line/Hobby construction.
% Regenerate from this directory only with:
% mpost --numbersystem=double --interaction=nonstopmode path-reference.mp
% Verification only; neither MetaPost nor these files are runtime inputs.
write "case,segment,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y" to "path-reference.csv";
vardef emit_reference(expr name, p) =
  for i = 0 upto length p - 1:
    save a,b,c,d; pair a,b,c,d;
    a := point i of p;
    b := postcontrol i of p;
    c := precontrol (i+1) of p;
    d := point (i+1) of p;
    write name & "," & decimal i & ","
      & decimal xpart a & "," & decimal ypart a & ","
      & decimal xpart b & "," & decimal ypart b & ","
      & decimal xpart c & "," & decimal ypart c & ","
      & decimal xpart d & "," & decimal ypart d to "path-reference.csv";
  endfor
enddef;
emit_reference("line_then_smooth", (0,0)--(60,80)..(130,20)..(210,90));
emit_reference("smooth_then_line", (0,0)..(60,80)..(130,20)--(210,90));
emit_reference("mixed_closed", (0,0)..(90,10)--(110,100)..(10,80)..cycle);
emit_reference("split_closed", (0,0)..(90,10)--(110,100)..(10,80)--cycle);
emit_reference("one_smooth", (0,0)--(60,80)..(130,20)--(210,90));
end.
