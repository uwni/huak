% Independent numerical oracle, not a huak build/runtime dependency.
% MetaPost 3.00 (TeX Live 2026), --numbersystem=double.
% Refresh from a scratch directory with:
%   mpost --numbersystem=double --interaction=nonstopmode envelope-reference.mp
% The CSV retains every cubic control point, including straight/degenerate
% pieces. A closed DRAW opens the cycle at its cut, joins both directed sides,
% and forces round caps at that cut. Two separate directional envelopes are
% insufficient for wide pens/small loops. Winding defines filled coverage.
% Independent actual-draw coverage lives in envelope-coverage.mp/.csv.
string reference_file;
reference_file := "envelope-reference.csv";
write "case,contour,segment,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y" to reference_file;

vardef emit_curve(expr name, contour, p) =
  for i = 0 upto length p - 1:
    save a,b,c,d; pair a,b,c,d;
    a := point i of p;
    b := postcontrol i of p;
    c := precontrol (i+1) of p;
    d := point (i+1) of p;
    write name & "," & decimal contour & "," & decimal i & ","
      & decimal xpart a & "," & decimal ypart a & ","
      & decimal xpart b & "," & decimal ypart b & ","
      & decimal xpart c & "," & decimal ypart c & ","
      & decimal xpart d & "," & decimal ypart d to reference_file;
  endfor
enddef;

% Prefer the first existing regular smooth knot. This keeps the original
% cubics intact when their incoming/outgoing nonzero tangents share a ray.
% The remaining closed fixture is all corners and cuts its first edge at .5.
vardef stroke_cut(expr center) =
  save selected, incoming, outgoing, knot; numeric selected; pair incoming,outgoing,knot;
  selected := -1;
  for i=0 upto length center-1:
    knot := point i of center;
    incoming := knot - precontrol i of center;
    outgoing := postcontrol i of center - knot;
    if (selected < 0) and (incoming <> origin) and (outgoing <> origin):
      if (xpart incoming * ypart outgoing = ypart incoming * xpart outgoing)
        and (xpart incoming * xpart outgoing + ypart incoming * ypart outgoing > 0):
        selected := i;
      fi;
    fi;
    exitif selected >= 0;
  endfor
  if selected < 0: selected := .5; fi;
  selected
enddef;

vardef emit_envelope(expr name, nib, center, capvalue, joinvalue, limitvalue) =
  save boundary, opened, cut; path boundary, opened; numeric cut;
  interim linecap := capvalue;
  interim linejoin := joinvalue;
  interim miterlimit := limitvalue;
  if cycle center:
    cut := stroke_cut(center);
    opened := subpath (cut,length center+cut) of center;
    if cycle opened: errmessage "closed stroke cut must be open"; fi;
    if point 0 of opened <> point length opened of opened:
      errmessage "closed stroke cut must retain its coincident endpoints";
    fi;
    interim linecap := rounded;
    boundary := envelope nib of opened;
  else:
    boundary := envelope nib of center;
  fi;
  emit_curve(name, 0, boundary);
enddef;

pen R, S, T;
path C, A, B, Z;
R := pensquare xscaled 4 yscaled 2;
S := R slanted .5 shifted (3,-2);
T := makepen((-2,-1)--(3,0)--(-1,4)--cycle);

A := (0,0)..controls (20,10) and (30,35)..(60,40);
B := (0,0)..controls (15,35) and (45,-35)..(60,0);
emit_envelope("cubic-monotone", R, A, rounded, rounded, 4);
emit_envelope("cubic-inflection", R, B, rounded, rounded, 4);
emit_envelope("cubic-inflection-reversed", R, reverse B, rounded, rounded, 4);
emit_envelope("cubic-sheared-offset", S, B, rounded, rounded, 4);
emit_envelope("cubic-triangle", T, B, rounded, rounded, 4);
A := (0,0)..controls (10,0) and (-10,0)..(0,0);
emit_envelope("cubic-cusp", R, A, rounded, rounded, 4);
emit_envelope("cubic-cusp-reversed", R, reverse A, rounded, rounded, 4);
A := (0,0)..controls (10,0) and (-10,.0001)..(0,0);
emit_envelope("cubic-near-cusp", R, A, rounded, rounded, 4);
emit_envelope("cubic-near-cusp-reversed", R, reverse A, rounded, rounded, 4);
A := (10,-10)..controls (-10/3,10) and (-10/3,-10)..(10,10);
emit_envelope("semicusp", R, A, rounded, rounded, 4);
emit_envelope("semicusp-reversed", R, reverse A, rounded, rounded, 4);
emit_envelope("semicusp-sheared", S, A, rounded, rounded, 4);
emit_envelope("semicusp-sheared-reversed", S, reverse A, rounded, rounded, 4);
A := (10,-10)..controls (-10/3,10+0.000000000001) and (-10/3,-10)..(10,10);
emit_envelope("semicusp-tiny", R, A, rounded, rounded, 4);
emit_envelope("semicusp-tiny-reversed", R, reverse A, rounded, rounded, 4);
emit_envelope("semicusp-tiny-sheared", S, A, rounded, rounded, 4);
emit_envelope("semicusp-tiny-sheared-reversed", S, reverse A, rounded, rounded, 4);
A := (10,-10)..controls (-10/3,10+0.000001) and (-10/3,-10)..(10,10);
emit_envelope("semicusp-near", R, A, rounded, rounded, 4);
emit_envelope("semicusp-near-reversed", R, reverse A, rounded, rounded, 4);
emit_envelope("semicusp-near-sheared", S, A, rounded, rounded, 4);
emit_envelope("semicusp-near-sheared-reversed", S, reverse A, rounded, rounded, 4);

C := (0,0)--(20,0)--(20,20);
emit_envelope("corner-butt-bevel", R, C, butt, beveled, 4);
emit_envelope("corner-square-bevel", R, C, squared, beveled, 4);
emit_envelope("corner-round-bevel", R, C, rounded, beveled, 4);
emit_envelope("corner-butt-miter", R, C, butt, mitered, 4);
emit_envelope("corner-square-miter", R, C, squared, mitered, 4);
emit_envelope("corner-round-miter", R, C, rounded, mitered, 4);
emit_envelope("corner-butt-round", R, C, butt, rounded, 4);
emit_envelope("corner-square-round", R, C, squared, rounded, 4);
emit_envelope("corner-round-round", R, C, rounded, rounded, 4);

C := (0,0)--(20,0)--(5,5);
emit_envelope("acute-miter", R, C, butt, mitered, 4);
emit_envelope("acute-miter-limited", R, C, butt, mitered, 1);
C := (0,0)--(20,0)--(0,0);
emit_envelope("reversal-round", R, C, rounded, rounded, 4);

C := (20,0)..controls (20,11) and (11,20)..(0,20)
  ..controls (-11,20) and (-20,11)..(-20,0)
  ..controls (-20,-11) and (-11,-20)..(0,-20)
  ..controls (11,-20) and (20,-11)..cycle;
emit_envelope("closed-cubic", R, C, butt, rounded, 4);
emit_envelope("closed-cubic-reversed", R, reverse C, butt, rounded, 4);

C := (0,0)--(30,0)--(15,10)--(30,25)--(0,25)--cycle;
emit_envelope("closed-reflex-bevel", R, C, butt, beveled, 4);
emit_envelope("closed-reflex-miter", R, C, butt, mitered, 4);
emit_envelope("closed-reflex-round", R, C, butt, rounded, 4);
emit_envelope("closed-reflex-limited", R, C, butt, mitered, 1);

Z := (5,7)--(5,7);
emit_envelope("zero-butt", R, Z, butt, rounded, 4);
emit_envelope("zero-square", R, Z, squared, rounded, 4);
emit_envelope("zero-round", R, Z, rounded, rounded, 4);
Z := (5,7);
emit_envelope("singleton-butt", R, Z, butt, rounded, 4);
emit_envelope("singleton-square", R, Z, squared, rounded, 4);
emit_envelope("singleton-round", R, Z, rounded, rounded, 4);

write EOF to reference_file;
end
