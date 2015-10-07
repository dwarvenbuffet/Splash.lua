--[[
Copyright (c) 2015 Calvin Rose

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

local floor = math.floor
local pairs = pairs
local setmetatable = setmetatable
local unpack = unpack
local type = type
local abs = math.abs
local min = math.min
local max = math.max
local sqrt = math.sqrt
local assert = assert
local select = select
local wrap = coroutine.wrap
local yield = coroutine.yield

local SPACE_KEY_CONST = 2^25

local splash = {}
splash.__index = splash

-- Helper functions

local function assert_aabb(x, y, w, h)
    if w <= 0 or h <= 0 then
        error "Width and Height of an AABB must be greater than 0."
    end
end

local function array_copy(x)
    local ret = {}
    if not x then return nil end
    for i = 1, #x do ret[i] = x[i] end
    return ret
end

local function to_cell(cs, x, y)
    return floor(x / cs), floor(y / cs)
end

local function to_cell_box(cs, x, y, w, h)
    local x1, y1 = floor(x / cs), floor(y / cs)
    local x2, y2 = floor((x + w) / cs), floor((y + h) / cs)
    return x1, y1, x2, y2
end

-- Intersection Testing

local function aabb_aabb_intersect(a, b)
    return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and
           a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

local function aabb_circle_intersect(aabb, circle)
    local x, y, w, h = aabb[1], aabb[2], aabb[3], aabb[4]
    local xc, yc, r = circle[1], circle[2], circle[3]
    if xc < x - r then return false end
    if xc > x + w + r then return false end
    if yc < y - r then return false end
    if yc > y + h + r then return false end
    if xc < x then
        if yc < y then
            return r ^ 2 > (yc - y) ^ 2 + (xc - x) ^ 2
        elseif yc > y + h then
            return r ^ 2 > (yc - y - h) ^ 2 + (xc - x) ^ 2
        end
    elseif xc > x + w then
        if yc < y then
            return r ^ 2 > (yc - y) ^ 2 + (xc - x - w) ^ 2
        elseif yc > y + h then
            return r ^ 2 > (yc - y - h) ^ 2 + (xc - x - w) ^ 2
        end
    end
    return true
end

local function circle_circle_intersect(c1, c2)
    local dx, dy = c2[1] - c1[1], c2[2] - c1[2]
    local d2 = dx * dx + dy * dy
    local r2 = (c1[3] + c2[3])^2
    if d2 <= r2 then
        local inv_pen = 1 / sqrt(r2 - d2)
        return true, inv_pen * dx, inv_pen * dy
    end
    return false
end

-- Segment intersections should also return one or two times of intersection
-- from 0 to 1 for ray-casting
local function seg_circle_intersect(seg, circle)
    local px, py = seg[3] - seg[1], seg[4] - seg[2]
    local cx, cy = circle[1] - seg[1], circle[2] - seg[2]
    local pcx, pcy = px - cx, py - cy
    local pdotp = px * px + py * py
    local r2 = circle[3]^2
    local d2 = (px * cy - cx * py)^2 / pdotp
    local dt2 = (r2 - d2)
    if dt2 < 0 then return false end
    local dt = sqrt(dt2 / pdotp)
    local tbase = (px * cx + py * cy) / pdotp
    return tbase - dt <= 1 and tbase + dt >= 0, tbase - dt, tbase + dt
end

local function seg_seg_intersect(s1, s2)
    local dx1, dy1 = s1[3] - s1[1], s1[4] - s1[2]
    local dx2, dy2 = s2[3] - s2[1], s2[4] - s2[2]
    local dx3, dy3 = s1[1] - s2[1], s1[2] - s2[2]
    local d = dx1*dy2 - dy1*dx2
    if d == 0 then return false end -- collinear
    local t1 = (dx2 * dy3 - dy2 * dx3) / d
    if t1 < 0 or t1 > 1 then return false end
    local t2 = (dx1 * dy3 - dy1 * dx3) / d
    if t2 < 0 or t2 > 1 then return false end
    return true, t1
end

local function seg_aabb_intersect(seg, aabb)
    local x1, y1, x2, y2 = seg[1], seg[2], seg[3], seg[4]
    local x, y, w, h = aabb[1], aabb[2], aabb[3], aabb[4]
    local idx, idy = 1 / (x2 - x1), 1 / (y2 - y1)
    local rx, ry = x - x1, y - y1
    local tx1, tx2, ty1, ty2
    if idx > 0 then
        tx1, tx2 = rx * idx, (rx + w) * idx
    else
        tx2, tx1 = rx * idx, (rx + w) * idx
    end
    if idy > 0 then
        ty1, ty2 = ry * idy, (ry + h) * idy
    else
        ty2, ty1 = ry * idy, (ry + h) * idy
    end
    local t1, t2 = max(tx1, ty1), min(tx2, ty2)
    return t1 <= t2 and t1 <= 1 and t2 >= 0, t1, t2
end

local intersections = {
    circle = {
        circle = circle_circle_intersect,
    },
    aabb = {
        aabb = aabb_aabb_intersect,
        circle = aabb_circle_intersect
    },
    seg = {
        seg = seg_seg_intersect,
        aabb = seg_aabb_intersect,
        circle = seg_circle_intersect
    }
}

-- Grid functions

local function grid_aabb(aabb, cs, f, ...)
    local x1, y1, x2, y2 = to_cell_box(cs, aabb[1], aabb[2], aabb[3], aabb[4])
    for gx = x1, x2 do
        for gy = y1, y2 do
            local a = f(gx, gy, ...)
            if a then return a end
        end
    end
end

local function grid_segment(seg, cs, f, ...)
    local x1, y1, x2, y2 = seg[1], seg[2], seg[3], seg[4]
    local sx, sy = x2 >= x1 and 1 or -1, y2 >= y1 and 1 or -1
    local x, y = to_cell(cs, x1, y1)
    local xf, yf = to_cell(cs, x2, y2)
    if x == xf and y == yf then
        local a = f(x, y, ...)
        if a then return a end
    end
    local dx, dy = x2 - x1, y2 - y1
    local dtx, dty = abs(cs / dx), abs(cs / dy)
    local tx = abs((floor(x1 / cs) * cs + (sx > 0 and cs or 0) - x1) / dx)
    local ty = abs((floor(y1 / cs) * cs + (sy > 0 and cs or 0) - y1) / dy)
    while x ~= xf or y ~= yf do
        f(x, y, ...)
        if tx > ty then
            ty = ty + dty
            y = y + sy
        else
            tx = tx + dtx
            x = x + sx
        end
    end
    return f(xf, yf, ...)
end

-- For now, just use aabb grid code. Large circles will be in extra cells.
local function grid_circle(circle, cs, f, ...)
    local x, y, r = circle[1], circle[2], circle[3]
    local x1, y1, x2, y2 = to_cell_box(cs, x - r, y - r, 2 * r, 2 * r)
    for cy = y1, y2 do
        for cx = x1, x2 do
            local a = f(cx, cy, ...)
            if a then return a end
        end
    end
end

local grids = {
    circle = grid_circle,
    aabb = grid_aabb,
    seg = grid_segment
}

-- Shapes

local function make_circle(x, y, r)
    return {type = "circle", x, y, r}
end

local function make_aabb(x, y, w, h)
    return {type = "aabb", x, y, w, h}
end

local function make_seg(x1, y1, x2, y2)
    return {type = "seg", x1, y1, x2, y2}
end

local function shape_grid(shape, cs, f, ...)
    return grids[shape.type](shape, cs, f, ...)
end

-- Static collisions
-- Returns boolean
local function shape_intersect(s1, s2)
    local f = intersections[s1.type][s2.type]
    if f then
        return f(s1, s2)
    else
        return intersections[s2.type][s1.type](s2, s1)
    end
end

-- Swept collisions
-- Returns nil or manifest if collision
-- format of manifest: x, y, t, nx, ny, px, py
local function shape_collide(s1, s2, xto, yto)

end

-- Splash functions

local function splash_new(cellSize)
    cellSize = cellSize or 128
    return setmetatable({
        cellSize = cellSize,
        count = 0,
        info = {}
    }, splash)
end

local function add_item_to_cell(cx, cy, self, item)
    local key = SPACE_KEY_CONST * cx + cy
    local l = self[key]
    if not l then l = {x = cx, y = cy}; self[key] = l end
    l[#l + 1] = item
end

local function remove_item_from_cell(cx, cy, self, item)
    local key = SPACE_KEY_CONST * cx + cy
    local l = self[key]
    if not l then return end
    for i = 1, #l do
        if l[i] == item then
            l[#l], l[i] = nil, l[#l]
            if #l == 0 then
                self[key] = nil
            end
            break
        end
    end
end

function splash:add(item, shape)
    assert(not self.info[item], "Item is already in world.")
    self.count = self.count + 1
    self.info[item] = shape
    shape_grid(shape, self.cellSize, add_item_to_cell, self, item)
    return item, shape
end

function splash:remove(item)
    local shape = self.info[item]
    assert(shape, "Item is not in world.")
    self.count = self.count - 1
    self.info[item] = nil
    shape_grid(shape, self.cellSize, remove_item_from_cell, self, item)
    return item, shape
end

function splash:update(item, shape)
    local oldshape = self.info[item]
    assert(oldshape, "Item is not in world.")
    -- Maybe optimize this later to avoid updating cells that haven't moved.
    -- In practice for small objects this probably works fine. It's certainly
    -- shorter than the more optimized version would be.
    shape_grid(oldshape, self.cellSize, remove_item_from_cell, self, item)
    shape_grid(shape, self.cellSize, add_item_to_cell, self, item)
    self.info[item] = shape
    return item, shape
end

-- Utility functions

function splash:shape(item)
    return self.info[item]
end

function splash:toCell(x, y)
    local cs = self.cellSize
    return floor(x / cs), floor(y / cs)
end

function splash:cellAabb(cx, cy)
    local cs = self.cellSize
    return make_aabb(cx * cs, cy * cs, cs, cs)
end

function splash:cellThingCount(cx, cy)
    local list = self[SPACE_KEY_CONST * cx + cy]
    if not list then return 0 end
    return #list
end

function splash:countCells()
    local count = 0
    for k, v in pairs(self) do
        if type(k) == "number" then count = count + 1 end
    end
    return count
end

-- Ray casting

local function ray_trace_helper(cx, cy, self, seg, ref)
    local list = self[SPACE_KEY_CONST * cx + cy]
    local info = self.info
    if not list then return false end
    for i = 1, #list do
        local item = list[i]
        -- Segment intersections should always return a time of intersection
        local c, t1 = shape_intersect(seg, info[item])
        if c and t1 <= ref[2] then
            ref[1], ref[2] = item, t1
        end
    end
    local tcx, tcy = to_cell(self.cellSize,
                             (1 - ref[2]) * seg[1] + ref[2] * seg[3],
                             (1 - ref[2]) * seg[2] + ref[2] * seg[4])
    if cx == tcx and cy == tcy then return true end
end

function splash:castRay(x1, y1, x2, y2)
    local ref = {false, 1}
    local seg = make_seg(x1, y1, x2, y2)
    grid_segment(seg, self.cellSize, ray_trace_helper, self, seg, ref)
    local t = max(0, ref[2])
    return ref[1], (1 - t) * x1 + t * x2, (1 - t) * y1 + t * y2, t
end

-- Map helper functions

local function map_shape_helper(cx, cy, self, seen, f, shape)
    local list = self[SPACE_KEY_CONST * cx + cy]
    if not list then return end
    local info = self.info
    for i = 1, #list do
        local item = list[i]
        if not seen[item] then
            local c, t1, t2 = shape_intersect(shape, info[item])
            if c then
                f(item, t1, t2)
            end
        end
        seen[item] = true
    end
end

-- Map functions

function splash:mapPopulatedCells(f)
    for k, list in pairs(self) do
        if type(k) == "number" then
            f(list.x, list.y)
        end
    end
end

function splash:mapShape(f, shape)
    local seen = {}
    return shape_grid(shape, self.cellSize,
        map_shape_helper, self, seen, f, shape)
end

function splash:mapCell(f, cx, cy)
    local list = self[SPACE_KEY_CONST * cx + cy]
    if not list then return end
    for i = 1, #list do f(list[i]) end
end

function splash:mapAll(f)
    local seen, ret = {}, {}
    for k, list in pairs(self) do
        if type(k) == "number" then
            for i = 1, #list do
                local thing = list[i]
                if not seen[thing] then
                    seen[thing] = true
                    f(thing)
                end
            end
        end
    end
end

-- Generate the iter versions of Map functions
local default_filter = function() return true end
local query_fn = function(ret, filter, n)
    if filter(n) then ret[#ret + 1] = n end
end
local box_query_fn = function(ret, filter, ...)
    if filter(...) then ret[#ret + 1] = {...} end
end
local function generate_query_iter(name, box_query, filter_index)
    local mapName = "map" .. name
    local iterName = "iter" .. name
    local queryName = "query" .. name
    splash[queryName] = function(self, ...)
        local ret = {}
        local filter = select(filter_index, ...) or default_filter
        self[mapName](self, filter, ...)
        return ret
    end
    splash[iterName] = function(self, a, b)
        return wrap(function() self[mapName](self, yield, a, b) end)
    end
end

generate_query_iter("Cell")
generate_query_iter("Shape")
generate_query_iter("All")
generate_query_iter("PopulatedCells")

-- Make the module
return setmetatable({
    new = splash_new,
    circle = make_circle,
    aabb = make_aabb,
    seg = make_seg
}, { __call = function(_, ...) return splash_new(...) end })
