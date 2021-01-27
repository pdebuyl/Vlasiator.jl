# Sample script for stream tracing using FieldTracer.
#
# Hongyang Zhou, hyzhou@umich.edu 01/27/2021

using PyPlot, FieldTracer, Vlasiator

Re = Vlasiator.Re

include("../plot/pyplot.jl")

filename = "bulk.0000501.vlsv"
nameρ = "rho"
nameV = "rho_v"

meta = read_meta(filename)

plot_pcolormesh(meta, nameρ)

v = read_variable(meta, nameV)
vx = reshape(v[1,:], meta.xcells, meta.ycells)
vy = reshape(v[2,:], meta.xcells, meta.ycells)
# tracing starting point
xstart, ystart = 12Re, 0Re
# regular Cartesian mesh
x = range(meta.xmin, meta.xmax, length=meta.xcells) 
y = range(meta.ymin, meta.ymax, length=meta.ycells)

# RK4 scheme by default
x1, y1 = trace2d(vx, vy, xstart, ystart, x, y;
   ds=0.5, maxstep=3000, gridType="ndgrid")
x1 ./= Re
y1 ./= Re

plot(x1, y1)

streamline(meta, nameV, comp="xy", color="w", density=1.0)