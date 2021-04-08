using Vlasiator
using Test

group = get(ENV, "TEST_GROUP", :all) |> Symbol

@testset "Vlasiator.jl" begin
   if Sys.iswindows()
      using ZipFile
      r = ZipFile.Reader("data/bulk_vlsv.zip")
      for file in r.files
         open(file.name, "w") do io
            write(io, read(file, String))
         end
      end
   else
      run(`unzip data/bulk_vlsv.zip`)
   end

   filenames = ["bulk.1d.vlsv", "bulk.2d.vlsv", "bulk.amr.vlsv"]

   if group in (:read, :all)
      @testset "Reading files" begin
         meta = readmeta(filenames[1])
         # Variable strings reading
         varnames = showvariables(meta)
         @test length(varnames) == 7 && varnames[end] == "vg_rhom"
         # Variable info reading
         varinfo = readvariableinfo(meta, "proton/vg_rho")
         @test varinfo.unit == "1/m^3"
         # Parameter checking
         @test hasparameter(meta, "dt") == true
         # Parameter reading
         t = readparameter(meta, "time")
         @test t == 8.0
         # unsorted ID
         cellIDs = readvariable(meta, "CellID", false)
         IDRef = UInt64[10, 9, 8, 7, 2, 1, 3, 4, 5, 6]
         @test cellIDs == IDRef
         indexRef = [6, 5, 7, 8, 9, 10, 4, 3, 2, 1]
         @test meta.cellIndex == indexRef
         # sorted var by default
         BC = readvariable(meta, "vg_boundarytype")
         @test BC == [4, 4, 1, 1, 1, 1, 1, 1, 3, 3]
         # ID finding
         loc = [2.0, 0.0, 0.0]
         id = getcell(meta, loc)
         coords = getcellcoordinates(meta, id)
         @test coords == [2.5, 0.0, 0.0]
         @test readvariable(meta, "proton/vg_rho", id)[1][1] ≈ 1.77599 atol=1e-5
         # ID in a line
         point1 = [-2.0, 0.0, 0.0]
         point2 = [2.0, 0.0, 0.0]
         cellids, _, _ = getcellinline(meta, point1, point2)
         @test cellids == collect(4:7)
         # Nearest ID with VDF stored
         @test getnearestcellwithvdf(meta, id) == 8

         # velocity space reading
         vcellids, vcellf = readvcells(meta, 2; pop="proton")
         V = getvcellcoordinates(meta, vcellids; pop="proton")
         @test V[:,end] == Float32[2.45, 1.95, 1.95]

         # AMR data reading, dccrg grid
         metaAMR = readmeta(filenames[3])
         maxreflevel = getmaxamr(metaAMR)
         sliceoffset = abs(metaAMR.ymin)
         idlist, indexlist = getslicecell(metaAMR, sliceoffset, maxreflevel,
            ymin=metaAMR.ymin, ymax=metaAMR.ymax)

         data = readvariable(metaAMR, "proton/vg_rho")
         data = refinedata(metaAMR, idlist, data[indexlist], maxreflevel, :y)
         @test sum(data) ≈ 7.690352275026747e8

         # AMR level
         @test getmaxamr(metaAMR) == 2
         @test getamr(metaAMR, idlist[1]) == 1

         # Compare two VLSV files
         @test compare(filenames[1], filenames[1])

         # Explicit IO closure required by Windows
         close(meta.fid)
         close(metaAMR.fid)
      end
   end

   if group in (:derive, :all)
      @testset "Derived variables" begin
         meta = readmeta(filenames[1])
         V = readvariable(meta, "Vmag") # derived quantity
         @test sortperm(V) == [7, 6, 5, 4, 3, 1, 2, 8, 9, 10]
         close(meta.fid)
      end
   end

   if group in (:plot, :all)
      @testset "Plotting" begin
         using PyPlot
         ENV["MPLBACKEND"]="agg" # no GUI
         # 1D
         meta = readmeta(filenames[1])
         ρ = readvariable(meta, "proton/vg_rho")
         plot_line(meta, "proton/vg_rho")
         line = gca().lines[1]
         @test line.get_ydata() == ρ

         # 2D
         meta = readmeta(filenames[2])
         p = plot_pcolormesh(meta, "proton/vg_rho")
         @test p.get_array()[end-2] ≈ 999535.7814279408 && length(p.get_array()) == 6300

         # 3D AMR
         meta = readmeta(filenames[3])
         p = plot_colormap3dslice(meta, "proton/vg_rho")
         @test p.get_array()[255] ≈ 1.04838862e6 && length(p.get_array()) == 512

         close(meta.fid)
      end
   end
         
   for file in filenames
      rm(file, force=true)
   end
end
