local smoldb = require"../smoldb"
-- we are using message-pack for encoding/decoding data
local msgpack = require"./msgpack"


local db = smoldb("", {
    packer = function(data)
        local state, err = pcall(msgpack.pack, data)
        if not state then return nil, err end
        return err
    end,
    unpacker = function(data)
        local state, err = pcall(msgpack.unpack, data)
        if not state then return nil, #data, err end
        return err, #data
    end,
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