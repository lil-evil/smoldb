local smodlb = require"../smoldb"

-- we open a database in memory
local db = smodlb()

-- set some basic values
db:set("string", "value")
db:set("number", 42)
db:set("boolean", true)
db:set("table", {age=19, hobbies = {"linux"}})

-- same with get
p("string", db:get("string"))
p("number", db:get("number"))
p("boolean", db:get("boolean"))
p("table", db:get("table"))

-- get has a great usage, it include a watcher !
-- every modification to tbl reflects to the database
local tbl = db:get("table")
tbl.age = 20
-- table library does not work as they use rawset and rawget, which ignore metatable (the watcher)
tbl.hobbies[#tbl.hobbies+1] = "lua"
p("watched data", tbl, db:get("table"))

-- if we want a copy of tbl which don't reflect on the database
local clone = tbl.__copy
clone.id = 1234
clone.age = 56
p("cloned data", clone, db:get("table"))

-- we can then use merge
db:merge("table", clone)
p("merged", db:get("table"))


-- if we want to export the database, it's possible!
print("before save", "database has "..#db .." entries") -- or db:size()
local save = db:export()

-- then destroy the database
db:destroy()
print("after destroy", "database has "..#db .." entries")

-- do some manipulation
db:set("key1", "value1")
db:set("key2", "value2")
db:set("key3", "value3")
print("after some set", "database has "..#db .." entries")

-- iterate on them
for k, v in db:iterator() do
    print("key: "..k, v)
end

-- then restore the save
db:import(save)
print("after restoring save", "database has "..#db .." entries")

for k, v in db:iterator() do
    print("key: "..k, v)
end