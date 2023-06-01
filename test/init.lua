local smoldb = require"../smoldb"
local fs = require"fs"
local openssl = require"openssl"
local pp = require"pretty-print"

fs.unlinkSync("data/smoldb.sqlite") -- ensure to use freshly created database
fs.mkdirSync("data") -- persistent database test
local test_count, test_failed = 0, 0

local function log(test, passed, reason)
    if type(passed) == "nil" then   -- start
        print(string.format( "[\x1b[1;35mstart\x1b[0m] : %s", test ))
        return
    end
    if type(test) == "number" and type(passed) == "number" then -- end
        print(string.format( "[\x1b[1;34mfinish\x1b[0m]: failed \x1b[4;31m%d\x1b[0m tests out of \x1b[4;34m%d\x1b[0m", passed, test ))
        return
    end
    if passed then  -- passing
        print(string.format( "[\x1b[32;1mpassed\x1b[0m]: \x1b[97m%s\x1b[0m", test ))
    else
        print(string.format( "[\x1b[31;1mfailed\x1b[0m]: \x1b[97m%s\x1b[0m\n    | \x1b[91m%s\x1b[0m", test, reason ))
    end
end

local function test(name, func)
    test_count = test_count + 1
    local status, err = pcall(func)

    if not status then 
        test_failed = test_failed + 1
        log(name, false, err:match('^([^\n]+)'))
    else
        log(name, true)
    end
end

local function cover(name, options)
    local db = smoldb(name, options)

    -- populating database
    for i = 0, 100 do
        db:set(openssl.hex(openssl.random(5)), {id=i, data=math.random()})
    end

    local value = {somedata="Hello World!"}
    test("set(key, value)", function()
        db:set("key", value)
        assert(db:has("key"), "did not set property 'key'")
    end)

    test("get(key)", function()
        local data = db:get("key")
        assert(data.somedata == value.somedata, "did not get property 'key'")
    end)

    test("ensure(key, default)", function()
        local data = db:ensure("ensured", value)
        assert(data.somedata == value.somedata, "did not ensure (returned) property 'ensured'")
        assert(db:has("ensured"), "did not ensure (created) property 'ensured'")
    end)

    test("has(key)", function()
        assert(db:has("ensured"), "return falsy value (false to existing key)")
        assert(not db:has("notexisting"), "return falsy value (true to not existing key)")
    end)

    test("delete(key)", function()
        db:delete("key")
        assert(not db:has("key"), "did not delete property 'key'")
    end)

    test("merge(key, value)", function()
        db:merge("ensured", {1,2,3, bool=true})
        assert(#db:get("ensured") == 3, "did not properly merged")
    end)

    test("fetch(key, force, nocache)", function()
        local data = db:fetch("ensured", true, false)
        assert(data.somedata == value.somedata, "did not correctly fetched 'ensured'")
    end)

    test("fetch_all(nocache)", function()
        local data = db:fetch_all(true)
        local len = 0
        for k,v in pairs(data) do len = len + 1 end
        assert(len == #db, "did not correctly fetched all database")
    end)
    -- write() is used internally by already tested function

    test("iterator()", function()
        local i = 0
        for k, v in db:iterator() do
            i = i + 1
        end
        assert(i == #db, "did not correctly iterated through all database")
    end)

    test("keys()", function()
        local data = db:keys()
        assert(#data == #db, "did not correctly iterated through all database")
    end)

    test("values()", function()
        local data = db:values()
        assert(#data == #db, "did not correctly iterated through all database")
    end)

    test("random(count, nocache)", function()
        local i1, i2, i3 = db:random(3, true)
        assert(i1 ~= nil and i2 ~= nil and i3 ~= nil, "did not retreive asked number of items")
    end)

    test("clear_cache(key)", function()
        if not options.cache then return end

        db:clear_cache("ensured")
        assert(db.cache["ensured"] == nil, "did not decached 'ensured'")

        db:clear_cache()
        local len = 0
        for k,v in pairs(db.cache) do len = len + 1 end
        assert(len == 0, "didi not cleared cache")
    end)

    test("get_info()", function()
        local info = db:get_info()
        assert(info.version == db.package.version, "did not provide correct version")
        assert(info.name == db.name, "did not provide correct database name")
        assert(info.created_date ~=0, "did not provide valid creation date")
    end)

    local save
    test("export()", function()
        save = db:export()
        local len = 0
        for k,v in db:iterator() do
            len = len + 1
            assert(pp.dump(save.data[k], false, true) == pp.dump(v, false, true), "did not export correctly ("..k..")")
        end
        local len2 = 0
        for k,v in pairs(save.data) do
            len2 = len2 + 1
        end
        assert(len == len2, "data length missmatch")
    end)

    test("destroy()", function()
        db:destroy()
        assert(#db == 0, "did not destroy database")
    end)

    test("import(save)", function()
        db:import(save)
        local len = 0
        for k,v in db:iterator() do
            len = len + 1
            assert(table.concat(save.data[k]) == table.concat(v), "did not export correctly ("..k..")")
        end
        local len2 = 0
        for k,v in pairs(save.data) do
            len2 = len2 + 1
        end
        assert(len == len2, "data length missmatch")
    end)

    -- encode and decode are used internally all the time
    -- __error is a internal function used to either throw or return error
    db:close()
end
log("Volatile database (in memory) with cache on")
cover("", {cache = true, throw = true})
log("Volatile database (in memory) with cache off")
cover("", {cache = false, throw = true})
log("Persistent database (data/smoldb.sqlite) with cache on")
cover("test_with_cache", {dir="data", cache = true, throw = true})
log("Persistent database (data/smoldb.sqlite) with cache off")
cover("test_without_cache", {dir="data", cache = true, throw = true})
log("Custom packer/unpacker")


local secret_key = "1234321"
local function encode(data)
    local cipher = openssl.cipher.get("des")
    local packed, err = smoldb:encode(data)
    if not packed then return nil, err end

    local status, encrypted = pcall(cipher.encrypt, cipher, packed, secret_key)
    if not status then
        return nil, encrypted
    else
        return encrypted
    end
end
local function decode(data)
    local cipher = openssl.cipher.get("des")

    local status, decrypted = pcall(cipher.decrypt, cipher, data, secret_key)
    if not status then
        return nil, #data, decrypted
    else
        local unpacked, len, err = smoldb:decode(decrypted)
        return unpacked, len, err
    end
end

cover("test_encrypted", {dir="data", cache = true, throw = true, packer = encode, unpacker = decode})

log(test_count, test_failed)