# 1D plot animation.
#
# ffmpeg is required to be installed for saving into mp4.
#
# Hongyang Zhou, hyzhou@umich.edu

using Vlasiator, Glob, PyPlot, Printf

files = glob("bulk.*.vlsv", ".")
# Choose plotting variable
var = "proton/vg_rho"

fig = plt.figure(constrained_layout=true)
# Fix axis limits according to data range
ax = plt.axes(xlim=(-10, 10), ylim=(0, 4))

line, = ax.plot([], [], lw=3, marker="*")

function animate(i::Int, files::Vector{String}, var::String, ax, line)
   meta = load(files[i+1])
   x = LinRange(meta.coordmin[1], meta.coordmax[1], meta.ncells[1])
   y = readvariable(meta, var)
   line.set_data(x, y)

   t = readparameter(meta, "time")
   str_title = @sprintf "t = %4.1fs, var = %s" t var
   ax.set_title(str_title)

   return (line,)
end

# https://matplotlib.org/stable/api/_as_gen/matplotlib.animation.FuncAnimation.html
anim = matplotlib.animation.FuncAnimation(fig, animate, fargs=(files, var, ax, line),
   frames=length(files), blit=true,
   repeat_delay=1000, interval=200)
# Make sure ffmpeg is available!
anim.save("line.mp4", writer="ffmpeg", fps=30)