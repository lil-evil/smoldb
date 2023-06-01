local smoldb = require"../smoldb"
local json = require"json"

-- volatile database
local db = smoldb("", {
    packer = json.encode,
    unpacker = json.decode,
    -- ensure that we get data directly from database, not cached objects
    cache = false
})

-- add some randomness
math.randomseed(os.time(), os.clock())
for i=1, 10 do
    db:set("key-"..i, {random=math.random()})
end

db:set("string", "hello")
db:set("number", 42)
db:set("boolean", true)

print("database entries : " .. #db)

p("keys", db:keys())
p("values", db:values())
p("random", db:random(2))