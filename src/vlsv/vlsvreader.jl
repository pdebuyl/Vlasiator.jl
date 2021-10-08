# VLSV reader in Julia

include("vlsvvariables.jl")

using EzXML, FLoops
using Mmap: mmap

export MetaVLSV, VarInfo
export load, readvariable, readparameter, readvariablemeta, readvcells, getvcellcoordinates,
       hasvariable, hasparameter, hasname, hasvdf

"Velocity mesh information."
struct VMeshInfo
   "number of velocity blocks"
   vblocks::SVector{3, Int64}
   vblock_size::SVector{3, Int64}
   vmin::SVector{3, Float64}
   vmax::SVector{3, Float64}
   dv::SVector{3, Float64}
end

"Variable MetaVLSV from the vlsv footer."
struct VarInfo
   "unit of the variable as a string"
   unit::String
   "unit of the variable as a LaTeX-formatted string"
   unitLaTeX::LaTeXString
   "description of the variable as a LaTeX-formatted string"
   variableLaTeX::LaTeXString
   "conversion factor to SI units as a string"
   unitConversion::String
end

"VLSV meta data."
struct MetaVLSV
   name::String
   dir::String
   fid::IOStream
   footer::EzXML.Node
   variable::Vector{String}
   "sorted cell IDs"
   cellid::Vector{UInt64}
   "ordered sequence index of raw cell IDs"
   cellIndex::Vector{Int64}
   time::Float64
   maxamr::Int64
   ncells::SVector{3, Int64}
   block_size::SVector{3, Int64}
   coordmin::SVector{3, Float64}
   coordmax::SVector{3, Float64}
   dcoord::SVector{3, Float64}
   populations::Vector{String}
   meshes::Dict{String, VMeshInfo}
end


function Base.show(io::IO, meta::MetaVLSV)
   println(io, "File: ", meta.name)
   println(io, "Time: ", round(meta.time, digits=2))
   println(io, "Dimension: $(ndims(meta))")
   println(io, "Maximum AMR level: $(meta.maxamr)")
   println(io, "Contains VDF: $(hasvdf(meta))")
   print(io, "variables: ")
   println(io, meta.variable)
end

function Base.show(io::IO, s::VarInfo)
   println(io, "Variable in LaTeX: ", s.variableLaTeX)
   println(io, "Unit: ", s.unit)
   println(io, "Unit in LaTeX: ", s.unitLaTeX)
   println(io, "Unit conversion: ", s.unitConversion)
end

"Return the xml footer of vlsv."
function getfooter(fid::IOStream)
   # First 8 bytes indicate big-endian or else
   endian_offset = 8
   seek(fid, endian_offset)
   # Obtain the offset of the XML file
   offset = read(fid, UInt64)
   seek(fid, offset)
   footer = read(fid, String) |> parsexml |> root
end


"Return size and type information for the object."
function getObjInfo(fid::IOStream, footer, name, tag, attr)
   local arraysize, datasize, datatype, vectorsize, variable_offset
   isFound = false

   for var in findall("//$tag", footer)
      if var[attr] == String(name)
         arraysize = parse(Int, var["arraysize"])
         datasize = parse(Int, var["datasize"])
         datatype = var["datatype"]
         vectorsize = parse(Int, var["vectorsize"])
         variable_offset = parse(Int, nodecontent(var))
         isFound = true
         break
      end
   end

   !isFound && throw(ArgumentError("unknown variable $name"))

   if datatype == "float"
      T = datasize == 4 ? Float32 : Float64
   elseif datatype == "int"
      T = datasize == 4 ? Int32 : Int64
   elseif datatype == "uint"
      T = datasize == 4 ? UInt32 : UInt64
   end

   T, variable_offset, arraysize, datasize, vectorsize
end

"Return vectors of `name` from the vlsv file with `footer` opened by `fid`."
function readvector(fid::IOStream, footer, name, tag)
   T, offset, arraysize, datasize, vectorsize = getObjInfo(fid, footer, name, tag, "name")

   if Sys.free_memory() > Int(1e9) + arraysize*vectorsize*datasize # > 1GB of free memory
      w = vectorsize == 1 ?
         Vector{T}(undef, arraysize) :
         Array{T,2}(undef, vectorsize, arraysize)
      seek(fid, offset)
      read!(fid, w)
   else
      @warn "Less than 1GB free memory detected. Using memory-mapped I/O!" maxlog=1
      a = mmap(fid, Vector{UInt8}, sizeof(T)*vectorsize*arraysize, offset)
      w = vectorsize == 1 ?
         reinterpret(T, a) :
         reshape(reinterpret(T, a), vectorsize, arraysize)
   end

   w
end

"""
    load(file) -> MetaVLSV

Return MetaVLSV from a vlsv `file`.
"""
function load(file::AbstractString)
   isfile(file) || throw(ArgumentError("Cannot open \'$file\': not a file"))
   fid = open(file, "r")

   footer = getfooter(fid)

   local cellid
   let
      T, offset, arraysize, _, vectorsize = 
         getObjInfo(fid, footer, "CellID", "VARIABLE", "name")
      a = mmap(fid, Vector{UInt8}, sizeof(T)*vectorsize*arraysize, offset)
      cellid = reinterpret(T, a)
   end

   cellIndex = sortperm(cellid)

   bbox = readmesh(fid, footer, "SpatialGrid", "MESH_BBOX")

   nodeCoordsX = readmesh(fid, footer, "SpatialGrid", "MESH_NODE_CRDS_X")
   nodeCoordsY = readmesh(fid, footer, "SpatialGrid", "MESH_NODE_CRDS_Y")
   nodeCoordsZ = readmesh(fid, footer, "SpatialGrid", "MESH_NODE_CRDS_Z")

   @inbounds ncells = SVector(bbox[1], bbox[2], bbox[3])
   @inbounds block_size = SVector(bbox[4], bbox[5], bbox[6])
   @inbounds coordmin = SVector(nodeCoordsX[begin], nodeCoordsY[begin], nodeCoordsZ[begin])
   @inbounds coordmax = SVector(nodeCoordsX[end], nodeCoordsY[end], nodeCoordsZ[end])

   dcoord = SVector{3}(@. (coordmax - coordmin) / ncells)

   meshes = Dict{String, VMeshInfo}()

   # Find all populations by the BLOCKIDS tag
   populations = String[]

   for varinfo in findall("//BLOCKIDS", footer)

      if haskey(varinfo, "name")
         # VLSV 5.0 file with bounding box
         popname = varinfo["name"]

         bbox = readmesh(fid, footer, popname, "MESH_BBOX")

         nodeCoordsX = readmesh(fid, footer, popname, "MESH_NODE_CRDS_X")
         nodeCoordsY = readmesh(fid, footer, popname, "MESH_NODE_CRDS_Y")
         nodeCoordsZ = readmesh(fid, footer, popname, "MESH_NODE_CRDS_Z")
         vblocks = SVector(bbox[1], bbox[2], bbox[3])
         vblock_size = SVector(bbox[4], bbox[5], bbox[6])
         vmin = @SVector [nodeCoordsX[begin], nodeCoordsY[begin], nodeCoordsZ[begin]]
         vmax = @SVector [nodeCoordsX[end], nodeCoordsY[end], nodeCoordsZ[end]]
         dv = SVector{3}(@. (vmax - vmin) / vblocks / vblock_size)
      else
         popname = "avgs"

         if "vxblocks_ini" in getindex.(findall("//PARAMETER", footer), "name")
            # In VLSV before 5.0 the mesh is defined with parameters.
            vblocks = SVector(
               readparameter(fid, footer, "vxblocks_ini"),
               readparameter(fid, footer, "vyblocks_ini"),
               readparameter(fid, footer, "vzblocks_ini"))
            vblock_size = @SVector [4, 4, 4]
            vmin = @SVector [
               readparameter(fid, footer, "vxmin"),
               readparameter(fid, footer, "vymin"),
               readparameter(fid, footer, "vzmin") ]
            vmax = @SVector [
               readparameter(fid, footer, "vxmax"),
               readparameter(fid, footer, "vymax"),
               readparameter(fid, footer, "vzmax") ]
            dv = SVector{3}(@. (vmax - vmin) / vblocks / vblock_size)
         else
            # No velocity space info, e.g., file not written by Vlasiator
            vblocks = @SVector [0, 0, 0]
            vblock_size = @SVector [4, 4, 4]
            vmin = @SVector [0, 0, 0]
            vmax = @SVector [0, 0, 0]
            dv = @SVector [1, 1, 1]
         end
      end

      # Update list of active populations
      if popname ∉ populations
         push!(populations, popname)
      end

      # Create a new object for this population
      popVMesh = VMeshInfo(vblocks, vblock_size, vmin, vmax, dv)

      meshes[popname] = popVMesh
   end

   if hasname(footer, "PARAMETER", "time") # Vlasiator 5.0+
      timesim = readparameter(fid, footer, "time")
   elseif hasname(footer, "PARAMETER", "t")
      timesim = readparameter(fid, footer, "t")
   else
      timesim = Inf
   end

   # Obtain maximum refinement level
   ncell = prod(ncells)
   maxamr, cid = 0, ncell
   while @inbounds cid < cellid[cellIndex[end]]
      maxamr += 1
      cid += ncell*8^maxamr
   end

   varinfo = findall("//VARIABLE", footer)
   nVar = length(varinfo)
   vars = Vector{String}(undef, nVar)
   for i in eachindex(vars, varinfo)
      @inbounds vars[i] = varinfo[i]["name"]
   end

   # File IOstream is not closed for sake of data processing later.

   meta = MetaVLSV(basename(file), dirname(file), fid, footer, vars, cellid[cellIndex],
      cellIndex, timesim, maxamr, ncells, block_size, coordmin, coordmax, dcoord,
      populations, meshes)
end


"""
    readvariablemeta(meta, var) -> VarInfo

Return VarInfo about `var` in the vlsv file linked to `meta`.
"""
function readvariablemeta(meta::MetaVLSV, var)

   varSym = isa(var, AbstractString) ? Symbol(var) : var

   unit, unitLaTeX, variableLaTeX, unitConversion = "", "", "", ""

   if varSym in keys(units_predefined)
      unit, variableLaTeX, unitLaTeX = units_predefined[varSym]
   elseif hasvariable(meta, var) # For Vlasiator 5 vlsv files, MetaVLSV is included
      for varinfo in findall("//VARIABLE", meta.footer)
         if varinfo["name"] == var
            unit = varinfo["unit"]
            unitLaTeX = varinfo["unitLaTeX"]
            variableLaTeX = varinfo["variableLaTeX"]
            unitConversion = varinfo["unitConversion"]
         end
         # If var isn't predefined or unit isn't found, it will return nothing!
      end
   end

   VarInfo(unit, unitLaTeX, variableLaTeX, unitConversion)
end

"Return mesh related variable."
function readmesh(fid::IOStream, footer, typeMesh, varMesh)
   T, offset, arraysize, _, _ = getObjInfo(fid, footer, typeMesh, varMesh, "mesh")

   w = Vector{T}(undef, arraysize)
   seek(fid, offset)
   read!(fid, w)

   w
end

"""
    readvariable(meta::MetaVLSV, var, sorted::Bool=true) -> Array

Return variable value of `var` from the vlsv file. By default `sorted=true`, which means
that for DCCRG grid the variables are sorted by cell ID.
"""
function readvariable(meta::MetaVLSV, var, sorted::Bool=true)
   @unpack fid, footer, cellIndex = meta
   if (local symvar = Symbol(var)) in keys(variables_predefined)
      data = variables_predefined[symvar](meta)
      return data
   end

   raw = readvector(fid, footer, var, "VARIABLE")

   if startswith(var, "fg_") # fsgrid
      bbox = SVector{6}(Vlasiator.readmesh(meta.fid, meta.footer, "fsgrid", "MESH_BBOX"))
      # Determine fsgrid domain decomposition
      nIORanks = readparameter(meta, "numWritingRanks")

      if ndims(raw) > 1
         @inbounds dataOrdered = zeros(Float32, size(raw,1), bbox[1], bbox[2], bbox[3])
      else
         @inbounds dataOrdered = zeros(Float32, bbox[1], bbox[2], bbox[3])
      end

      @inbounds fgDecomposition = @views getDomainDecomposition(bbox[1:3], nIORanks)

      currentOffset = ones(UInt32, nIORanks+1)
      lsize = ones(Int, 3, nIORanks)
      lstart = similar(lsize)
      @inbounds @views @floop for i = 1:nIORanks
         xyz = SA[
            (i - 1) ÷ fgDecomposition[3] ÷ fgDecomposition[2],
            (i - 1) ÷ fgDecomposition[3] % fgDecomposition[2],
            (i - 1) % fgDecomposition[3] ]

         lsize[:,i] = calcLocalSize.(bbox[1:3], fgDecomposition, xyz)
         lstart[:,i] = calcLocalStart.(bbox[1:3], fgDecomposition, xyz)

         totalSize = prod(lsize[:,i])
         currentOffset[i+1] = currentOffset[i] + totalSize

         # Reorder data
         if ndims(raw) > 1
            lend = lstart[:,i] + lsize[:,i] .- 1

            ldata = raw[:,currentOffset[i]:currentOffset[i+1]-1]
            ldata = reshape(ldata, size(raw,1), lsize[1,i], lsize[2,i], lsize[3,i])

            dataOrdered[:,lstart[1,i]:lend[1],lstart[2,i]:lend[2],lstart[3,i]:lend[3]] =
               ldata
         else
            ldata = raw[currentOffset[i]:currentOffset[i+1]-1]
            ldata = reshape(ldata, lsize[1,i], lsize[2,i], lsize[3,i])

            dataOrdered[lstart[1,i]:lend[1],lstart[2,i]:lend[2],lstart[3,i]:lend[3]] = ldata
         end
      end

      data = dropdims(dataOrdered, dims=(findall(size(dataOrdered) .== 1)...,))
   elseif sorted # dccrg grid
      @inbounds d = ndims(raw) == 1 ? raw[cellIndex] : raw[:,cellIndex]
      data = eltype(raw) == Float64 ? Float32.(d) : d
   else
      data = raw
   end
   return data
end

"""
    readvariable(meta::MetaVLSV, var, ids) -> Array

Read a variable `var` in a collection of cells `ids`.
"""
function readvariable(meta::MetaVLSV, var, ids)
   @assert !startswith(var, "fg_") "Currently does not support reading fsgrid!"
   @unpack fid, footer = meta

   if (local symvar = Symbol(var)) in keys(variables_predefined)
      data = variables_predefined[symvar](meta, ids)
      return data
   end

   T, offset, arraysize, _, vectorsize = 
      getObjInfo(fid, footer, var, "VARIABLE", "name")

   v = Array{T}(undef, vectorsize, length(ids))

   a = mmap(fid, Vector{UInt8}, sizeof(T)*vectorsize*arraysize, offset)
   w = reshape(reinterpret(T, a), vectorsize, arraysize)

   cellidRaw = readvector(fid, footer, "CellID", "VARIABLE")
   id_ = length(meta.cellIndex) < 1000 ?
      [findfirst(==(id), cellidRaw) for id in ids] :
      indexin(ids, cellidRaw)

   for i in eachindex(id_), iv = 1:vectorsize
      @inbounds v[iv,i] = w[iv,id_[i]]
   end
   if T == Float64
      v = Float32.(v)
   end
   return v
end

@inline Base.getindex(meta::MetaVLSV, key::AbstractString) = readvariable(meta, key)

"Return 2d scalar/vector data. Nonpublic because it won't work with DCCRG AMR."
function getdata2d(meta::MetaVLSV, var)
   @assert ndims(meta) == 2 "2D outputs required."
   sizes = filter(!=(1), meta.ncells)
   data = readvariable(meta, var)
   data = ndims(data) == 1 ?
      reshape(data, sizes[1], sizes[2]) :
      reshape(data, 3, sizes[1], sizes[2]) # assumes 3-vector, may not work in general
end

"File size in bytes."
@inline Base.size(meta::MetaVLSV) = filesize(joinpath(meta.dir, meta.name))

# Optimize decomposition of this grid over the given number of processors.
# Reference: fsgrid.hpp
function getDomainDecomposition(globalsize, nprocs)
   domainDecomp = @SVector [1, 1, 1]
   minValue = Inf

   @inbounds for i = 1:min(nprocs, globalsize[1])
      iBox = max(globalsize[1]/i, 1)

      for j = 1:min(nprocs, globalsize[2])
         i * j > nprocs && break

         jBox = max(globalsize[2]/j, 1)

         for k = 1:min(nprocs, globalsize[2])
            i * j * k > nprocs && continue

            kBox = max(globalsize[3]/k, 1)

            nyz = ifelse(i > 1, jBox * kBox, 0)
            nzx = ifelse(j > 1, kBox * iBox, 0)
            nxy = ifelse(k > 1, iBox * jBox, 0)

            v = 10*iBox*jBox*kBox + nyz + nzx + nxy

            if i * j * k == nprocs && v < minValue
               minValue = v
               domainDecomp = @SVector [i, j, k]
            end
         end
      end
   end

   domainDecomp
end

function calcLocalStart(globalCells, nprocs, lcells)
   ncells = globalCells ÷ nprocs
   remainder = globalCells % nprocs
   lstart = ifelse(lcells < remainder, lcells*(ncells+1) + 1, lcells*ncells + remainder + 1)
end

function calcLocalSize(globalCells, nprocs, lcells)
   ncells = globalCells ÷ nprocs
   remainder = globalCells % nprocs
   lsize = ifelse(lcells < remainder, ncells + 1, ncells)
end

"""
    hasvariable(meta, var) -> Bool

Check if the VLSV file contains a variable.
"""
hasvariable(meta::MetaVLSV, var) = hasname(meta.footer, "VARIABLE", var)

"""
    readparameter(meta, param)

Return the parameter value from vlsv file.
"""
readparameter(meta::MetaVLSV, param) = readparameter(meta.fid, meta.footer, param)

function readparameter(fid::IOStream, footer, param)
   T, offset, _, _, _ = getObjInfo(fid, footer, param, "PARAMETER", "name")
   seek(fid, offset)
   p = read(fid, T)
end

"""
    hasparameter(meta, param) -> Bool

Check if the vlsv file contains a certain parameter.
"""
hasparameter(meta::MetaVLSV, param) = hasname(meta.footer, "PARAMETER", param)

"Check if the XML `element` contains a `tag` with `name`."
function hasname(element, tag, name)
   isFound = false

   for var in findall("//$tag", element)
      var["name"] == name && (isFound = true)
      isFound && break
   end

   isFound
end

"""
    ndims(meta) -> Int

Return the dimension of VLSV data.
"""
Base.ndims(meta::MetaVLSV) = count(>(1), meta.ncells)

"""
    hasvdf(meta) -> Bool

Check if the VLSV file contains VDF.
"""
function hasvdf(meta::MetaVLSV)
   cells = readmesh(meta.fid, meta.footer, "SpatialGrid", "CELLSWITHBLOCKS")
   return !isempty(cells)
end

"""
    readvcells(meta, cid; pop="proton")

Read velocity cells from a spatial cell of ID `cid`, and return a map of velocity cell
ids and corresponding value.
"""
function readvcells(meta::MetaVLSV, cid; pop="proton")
   @unpack fid, footer = meta
   @unpack vblock_size = meta.meshes[pop]
   bsize = prod(vblock_size)

   local offset, nblocks
   let cellsWithVDF = readvector(fid, footer, pop, "CELLSWITHBLOCKS"),
       nblock_C = readvector(fid, footer, pop, "BLOCKSPERCELL")
      # Check if cells have vspace stored
      if cid ∈ cellsWithVDF
         cellWithVDFIndex = findfirst(==(cid), cellsWithVDF)
      else
         throw(ArgumentError("Cell ID $cid does not store velocity distribution!"))
      end
      # Navigate to the correct position
      offset = sum(@view nblock_C[1:cellWithVDFIndex-1])
      @inbounds nblocks = Int(nblock_C[cellWithVDFIndex])
   end

   local datasize, datatype, vectorsize, variable_offset
   # Read in avgs
   let varinfo = findfirst("//BLOCKVARIABLE", footer)
      datasize = parse(Int, varinfo["datasize"])
      datatype = varinfo["datatype"]
      @assert datatype == "float" "VDFs must be floating numbers!"
      vectorsize = parse(Int, varinfo["vectorsize"])
      variable_offset = parse(Int, nodecontent(varinfo))
   end

   data = let
      Tavg = datasize == 4 ? Float32 : Float64
      a = mmap(fid, Vector{UInt8}, sizeof(Tavg)*vectorsize*nblocks,
         offset*vectorsize*datasize + variable_offset)
      reshape(reinterpret(Tavg, a), vectorsize, nblocks)
   end

   # Read in block IDs
   let varinfo = findfirst("//BLOCKIDS", footer)
      datasize = parse(Int, varinfo["datasize"])
      datatype = varinfo["datatype"]
      @assert datatype == "uint" "Block ID must be unsigned integer!"
      variable_offset = parse(Int, nodecontent(varinfo))
   end

   blockIDs = let T = datasize == 4 ? UInt32 : UInt64
      Vector{T}(undef, nblocks)
   end
   seek(fid, offset * datasize + variable_offset)
   read!(fid, blockIDs)

   # Velocity cell IDs and corresponding distributions
   vcellids = zeros(UInt32, bsize*nblocks)
   vcellf = zeros(Float32, bsize*nblocks)

   vcellid_local = @inbounds [i + vblock_size[1]*j + vblock_size[1]*vblock_size[2]*k
      for i in 0:vblock_size[1]-1, j in 0:vblock_size[2]-1, k in 0:vblock_size[3]-1]

   @inbounds @floop for i in eachindex(blockIDs), j = 1:bsize
      vcellids[(i-1)*bsize+j] = vcellid_local[j] + bsize*blockIDs[i]
      vcellf[(i-1)*bsize+j] = data[j,i]
   end
   vcellids, vcellf
end


"""
    getvcellcoordinates(meta, vcellids, pop="proton")

Return velocity cells' coordinates of population `pop` and id `vcellids`.
"""
function getvcellcoordinates(meta::MetaVLSV, vcellids; pop="proton")
   @unpack vblocks, vblock_size, dv, vmin = meta.meshes[pop]

   bsize = prod(vblock_size)
   blockid = @. vcellids ÷ bsize
   # Get block coordinates
   @inbounds blockIndX = @. blockid % vblocks[1]
   @inbounds blockIndY = @. blockid ÷ vblocks[1] % vblocks[2]
   @inbounds blockIndZ = @. blockid ÷ (vblocks[1] * vblocks[2])
   @inbounds blockCoordX = @. blockIndX * dv[1] * vblock_size[1] + vmin[1]
   @inbounds blockCoordY = @. blockIndY * dv[2] * vblock_size[2] + vmin[2]
   @inbounds blockCoordZ = @. blockIndZ * dv[3] * vblock_size[3] + vmin[3]
   # Get cell indices
   cellids = @. vcellids % bsize
   @inbounds cellidx = @. cellids % vblock_size[1]
   @inbounds cellidy = @. cellids ÷ vblock_size[1] % vblock_size[2]
   @inbounds cellidz = @. cellids ÷ (vblock_size[1] * vblock_size[2])
   # Get cell coordinates
   cellCoords = Matrix{Float32}(undef, 3, length(cellids))
   @inbounds @floop for i in eachindex(cellids)
      cellCoords[1,i] = blockCoordX[i] + (cellidx[i] + 0.5) * dv[1]
      cellCoords[2,i] = blockCoordY[i] + (cellidy[i] + 0.5) * dv[2]
      cellCoords[3,i] = blockCoordZ[i] + (cellidz[i] + 0.5) * dv[3]
   end
   cellCoords
end