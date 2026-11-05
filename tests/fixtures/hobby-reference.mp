% Independent oracle for src/drawing/path/hobby.zig. Run only when refreshing fixtures:
% cd tests/fixtures && mpost --numbersystem=double --interaction=nonstopmode hobby-reference.mp
% MetaPost 3.00 (TeX Live 2026). No TeX calls, rendering, or runtime dependency.
% Each row: case, segment, p0.x,p0.y,p1.x,p1.y,p2.x,p2.y,p3.x,p3.y.
if unknown reference_file:
  string reference_file;
  reference_file := "hobby-reference.csv";
fi;
write "case,segment,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y" to reference_file;
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
      & decimal xpart d & "," & decimal ypart d to reference_file;
  endfor
enddef;
emit_reference("open", (0,0)..(60,80)..(130,20)..(210,90));
emit_reference("closed", (0,0)..(90,10)..(110,100)..(10,80)..cycle);
emit_reference("directions", (0,0){up}..(60,80)..(130,20){right});
emit_reference("tension", (0,0)..tension 1.7 and 0.8..(60,80)
  ..tension 0.75 and 2.2..(130,20)..tension 1.3 and 1.1..(210,90));
emit_reference("curl", (0,0){curl 0}..(60,80)..(130,20)..{curl 2.5}(210,90));
emit_reference("corner", (0,0)..(60,80){right}..{up}(130,20){left}..(210,90));
emit_reference("closed_direction", (0,0){right}..(90,10)..(110,100)..(10,80)..cycle);
emit_reference("closed_tension", (0,0)..tension 1.7 and 0.8..(90,10)
  ..tension 0.75 and 2.2..(110,100)..tension 1.3 and 1.1..(10,80)
  ..tension 1.1 and 1.4..cycle);
emit_reference("two_closed", (0,0)..(90,10)..cycle);
emit_reference("two_open", (0,0)..tension 1.7 and 0.8..(90,10));
emit_reference("two_given", (0,0){up}..tension 1.7 and 0.8..(90,10){right});
emit_reference("one_given", (0,0){up}..tension 1.7 and 0.8..(90,10));
emit_reference("tension_curl", (0,0){curl 2.5}..tension 0.75 and 2.2..(60,80)
  ..(130,20)..tension 1.3 and 1.1..{curl 0.2}(210,90));
write EOF to reference_file;
end
