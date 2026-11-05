% Actual MetaPost DRAW oracle. Generation only; never a runtime dependency.
% The retained CSV was sampled from these EPS files through Ghostscript and
% stored as fixed pixel-center occupancy in envelope-coverage.csv.
prologues := 3;
outputformat := "eps";
outputtemplate := "envelope-coverage-%c.mps";
linecap := rounded;
linejoin := rounded;
pen R; R := pensquare scaled 4;
path C;
numeric K; K := 4*(sqrt 2-1)/3;

vardef draw_reference(expr number, center) =
  beginfig(number);
    fill unitsquare scaled 40 withcolor white;
    draw center shifted (20,20) withpen R withcolor black;
  endfig;
enddef;

C := (1,0)..controls (1,K) and (K,1)..(0,1)
  ..controls (-K,1) and (-1,K)..(-1,0)
  ..controls (-1,-K) and (-K,-1)..(0,-1)
  ..controls (K,-1) and (1,-K)..cycle;
draw_reference(1, C);
draw_reference(2, reverse C);
C := (-6,-4)--(6,4)--(-6,4)--(6,-4)--cycle;
draw_reference(3, C);
C := (-6,-4)--(6,4)--(-6,4)--(6,-4);
draw_reference(4, C);
C := (-4,-4)--(4,-4)--(4,4)--(-4,4)--(-4,-4)
  --(4,-4)--(4,4)--(-4,4)--cycle;
draw_reference(5, C);
C := (-4,-4)--(4,-4)--(4,4)--(-4,4)--(-4,-4)
  --(-4,4)--(4,4)--(4,-4)--cycle;
draw_reference(6, C);
end
