  --[[lit-meta
    name = "lil-evil/smoldb"
    version = "1.1.1"
    dependencies = {
      "lil-evil/table-watcher",
      "SinisterRectus/sqlite3",
      --"creationix/msgpack"
    }
    description = "A sqlite3 code abstraction"
    tags = { "database", "sqlite3", "db" }
    license = "MIT"
    author = { name = "lilevil" }
    homepage = "https://github.com/lil-evil/smoldb"
  ]]
  
---@diagnostic disable: undefined-doc-param
---@module smoldb
local process = require"process".globalProcess()
local fs = require"fs"
local msgpack = nil

local table_watcher = require"table-watcher"
local sqlite = require"sqlite3"

local smoldb = {
  package = {version="1.1.1"},
  err = {}
}

-- internal
-- TODO as a lit package
local function test_option(opt, types, default)
  local state = false
  for _, t in ipairs(types) do
    -- type checking
    if type(t) == "string" then
      if state then break end -- match, no need to continue
      state = type(opt) == t

    -- user defined function checking
    elseif type(t) == "function" then
      state = t(opt)
    end
  end

  if not state then return default end
  return opt
end
-- https://gist.github.com/tylerneylon/81333721109155b2d244
local function deep_clone(obj, seen)
  -- Handle non-tables and previously-seen tables.
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end

  -- New table; mark it as seen and copy recursively.
  local s = seen or {}
  local res = {}
  s[obj] = res
  for k, v in pairs(obj) do res[deep_clone(k, s)] = deep_clone(v, s) end
  return res
end

-- https://stackoverflow.com/a/1283608
local function merge(t1, t2)
  for k,v in pairs(t2) do
      if type(v) == "table" then
          if type(t1[k] or false) == "table" then
              merge(t1[k] or {}, t2[k] or {})
          else
              t1[k] = v
          end
      else
          t1[k] = v
      end
  end
  return t1
end

local watcher_events = {
  get = function(t,k, self)
    if k == "__copy" then
      return self:ret(deep_clone(t))
    end
  end,
  set = function(t,k,v, self)
    t[k] = v
    self.smoldb:set(self.key, self.origin)

    return self.block
  end
}


-- close all database instance before exiting
local instances = {}
process:on("exit", function() for _, i in ipairs(instances) do i:close() end end)

--- initialize and connect to the database
---@param name string|nil if nil or empty string, database reside on memory
---@param options table|nil options
---@param options.dir string the directory where the database is located
---@param options.file string the file where the database is located
---@param options.mode string "ro", "rw", "rwc" (default)
---@param options.wal boolean see https://www.sqlite.org/wal.html
---@param options.cache boolean whether or not to cache data that have been fetch
---@param options.throw boolean if true, functions are allowed to call error() instead of returning (nil, "error")
---@param options.packer function data serializer, default msgpack.encode
---@param options.unpacker function data deserializer, default msgpack.decode
function smoldb:connect(name, options)
  local smdb = deep_clone(self)

  -- name check
  if (type(name) == "nil") or (type(name) == "string") then smdb.name = name or ""
  else error("name must be nil or a string (got ".. type(name) .." )") end

  -- options
  if (type(options) == "nil") or (type(options) == "table") then options = options or {}
  else error("options must be nil or a table (got ".. type(options) .." )") end
  smdb.options = {
    throw = test_option(options.throw, {"boolean"}, true),
    wal = test_option(options.wal, {"boolean"}, true),
    cache = test_option(options.cache, {"boolean"}, true),
    mode = test_option(options.mode, {"string", function(t) return t == "ro" or t == "rw" or t == "rwc" end}, "rwc"),
    dir = test_option(options.dir, {"string"}, "."),
    file = test_option(options.file, {"string"}, "smoldb.sqlite"),
    packer = test_option(options.packer, {"function"}, nil),
    unpacker = test_option(options.unpacker, {"function"}, nil),

  }
  -- dir and file check
  do
    local stat, err, err_ = fs.statSync(smdb.options.dir)
    if not stat then error("options.dir : " .. err) end
    if stat.type ~= "directory" then error("options.dir : ".. smdb.options.dir .." is not a directory") end

    stat, err, err_ = fs.statSync(smdb.options.dir.. "/" .. smdb.options.file)
    if not stat and (err_ == "ENOENT" and smdb.options.mode ~= "rwc") then
      error("options.file : " .. err)
    end
    if stat and stat.type ~= "file" then error("options.file : ".. smdb.options.dir .." is not a file") end
  end
  if smdb.name ~= "" then smdb.db_file = smdb.options.dir.. "/" .. smdb.options.file end

  -- connect
  local state, con = pcall(sqlite.open, (smdb.name == "" ) and "" or smdb.db_file, smdb.options.mode)
  if not state then
      error("smoldb error : could not open sqlite database : \n\t| "..con)
  else smdb.db = con end



  if smdb.options.cache then smdb.cache = {} end
  if smdb.options.wal then con:exec("PRAGMA journal_mode=WAL") else con:exec("PRAGMA journal_mode=DELETE") end

  con:exec("CREATE TABLE IF NOT EXISTS 'internal::smoldb' (tbl TEXT PRIMARY KEY NOT NULL, version VARCHAR(15), date int)")
  con:exec("CREATE TABLE IF NOT EXISTS '"..smdb.name.."' (key TEXT PRIMARY KEY NOT NULL, value TEXT)")
  con:exec("INSERT OR IGNORE INTO 'internal::smoldb' (tbl, version, date) VALUES ('"..smdb.name.."', '"..smdb.package.version.."', "..os.time()..");")
  
  -- version check
---@diagnostic disable-next-line: undefined-field
  if not _G.SMOLDB_IGNORE_VERSION then  
    local db_version = smdb:get_info().version
    if db_version < "1.1.0" then
      -- Yes thoses messages are annoying, but your data is important, operate carefully.
      print(string.format("\x1b[31;7mWARNING\x1b[27m : Database version (%s) missmatch with smoldb current version (%s).\x1b[0m", db_version, smoldb.package.version))
      print("\x1b[31;7mWARNING\x1b[27m : You will encounter data corruption if you keep using the database as is.\x1b[0m")
      print("\x1b[31;7mWARNING\x1b[27m : Please see https://github.com/lil-evil/smoldb/blob/master/README.md#changelog\x1b[0m")
      print("\x1b[31;7mWARNING\x1b[27m : The app wil now exit. To avoid this behavior, set \"SMOLDB_IGNORE_VERSION=true\" as global. Use at your own risk.\x1b[0m")
      con:close()
      os.exit(1) -- avoid any data corruption
    end
  else
    print("\x1b[31;7mWARNING\x1b[27m : smoldb will not check versions. Your data may end corrupted.\x1b[0m")
  end
  table.insert(instances, smdb)

  smdb.connect = nil
  smdb.handles = {}

  

  return setmetatable(smdb,
    {  __len = function(self) return self:size() end}
  )
end

--- close all handles and exit properly 
function smoldb:close()
  for _,i in ipairs(self.handles) do i:close() end
  self.db:close()
  for _,i in ipairs(instances) do if i == self then table.remove(instances, _) end end
end
--- throw or return nil, "error". internal syntax sugar
---@param err string error message
function smoldb:__error(err)
  if 
      self.options.throw then error(err, 2)
  else
      return self.err, err
  end
end
--- encode given data using custom packer or msgpack.encode by default
---@param data any
function smoldb:encode(data)
  local packer = type(self.options and self.options.packer) == "function" and self.options.packer or msgpack.encode
  
  local packed, error = packer(data)
  if error then 
      return self:__error(error)
  else
      return packed
  end
end
--- decode given data using custom unpacker or msgpack.decode by default
---@param data string
function smoldb:decode(data)
  local unpacker = type(self.options and self.options.packer) == "function" and self.options.unpacker or msgpack.decode
  
  local unpacked, _, err = unpacker(data)
  if err then 
      return self:__error(err)
  else
      return unpacked
  end
end

--- Get the number of items in the database
function smoldb:size()
  local state, err = pcall(self.db.prepare, self.db, "SELECT count(*) FROM '"..self.name.."'")
  if not state then return self:__error(err) else
  local value = err:step()
  err:close()
  return tonumber(value[1]) end
end

--- Return the key's value or nil
---@param key string the key to return
function smoldb:get(key)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  local data, err = self:fetch(key)
  if data == self.err then return self:__error(err) end

  if type(data) == "table" then
      local events = deep_clone(watcher_events)
      events.smoldb = self
      events.key = key

      return table_watcher.watch(data, events)
  else return data end
end

--- Set a value in the database
---@param key string the key to set the value to
---@param value any the value to set
function smoldb:set(key, value)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  local _, err = self:write(key, value)
  if _ == self.err then return self:__error(err) end

  if self.options.cache and type(self.cache) == "table" then
      self.cache[key] = value
  end
end

--- Return the key's value or set it to the default value if provided and return it
---@param key any the key to return
---@param default any default value if key does not exist
function smoldb:ensure(key, default)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  local data, err = self:fetch(key)
  if data == self.err then return self:__error(err), err end

  if data == nil then
    local _default = deep_clone(default)
      self:set(key, _default)
      data = _default
  end

  if type(data) == "table" then
      local events = deep_clone(watcher_events)
      events.smoldb = self
      events.key = key

      
      return table_watcher.watch(data, events)
  else return data end
end

--- return whether or not the key exists
---@param key any
function smoldb:has(key)
  if type(key) ~= "string" then return self:__error("key must be a string") end
  
  return self:fetch(key) ~= nil
end

--- merge database table with new table
---@param key string
---@param value any
function smoldb:merge(key, value)
  if type(key) ~= "string" then return self:__error("key must be a string") end
  
  local old, err = self:fetch(key)
  if old == self.err then return self:__error(err) end
  local new = value

  if type(value) == "table" and type(old)=="table" then
      new = merge(old, value)
  end

  local _, err = self:write(key, new)
  if _ == self.err then return self:__error(err) end
end

--- delete a key if it exists
---@param key string
function smoldb:delete(key)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  local state, err = pcall(self.db.prepare, self.db, "DELETE FROM '"..self.name.."' WHERE key = ?")

  if not state then return self:__error(err)
  else
      err:bind(key):step()
      err:close()

      if self.options.cache and type(self.cache) == "table" then
          self.cache[key] = nil
      end
  end

end

--- completly destroy any data and clear internal information about this database !! No going back !!
---@param name string database's name. default to self.name
function smoldb:destroy(name)
  name = name or self.name
  if type(name) ~= "string" then return self:__error("name must be a string") end

  local state, err = pcall(self.db.prepare, self.db, "DROP TABLE '"..name.."'")

  if not state then return self:__error(err)
  else
      err:step()
      err:close()
  end
  local state, err = pcall(self.db.prepare, self.db, "DELETE FROM 'internal::smoldb' WHERE tbl = '"..name.."'")
  if not state then return self:__error(err)
  else
      err:step()
      err:close()
  end

  local state, err = pcall(self.db.prepare, self.db, "CREATE TABLE IF NOT EXISTS '"..name.."' (key TEXT PRIMARY KEY NOT NULL, value TEXT)")
  if not state then return self:__error(err)
  else
      err:step()
      err:close()
  end
  local state, err = pcall(self.db.prepare, self.db, "INSERT OR IGNORE INTO 'internal::smoldb' (tbl, version, date) VALUES ('"..name.."', '"..self.package.version.."', "..os.time()..")")
  if not state then return self:__error(err)
  else
      err:step()
      err:close()
  end
end

---fetch data from the database or return cached value
---@param key string
---@param force boolean|nil whether or not to ignore cached value and force database's fetch
---@param nocache boolean|nil whether or not to not cache fetched value
function smoldb:fetch(key, force, nocache)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  if not force and type(self.cache) == "table" and self.options.cache then
      if self.cache[key] then return self.cache[key] end
  end
  local state, err = pcall(self.db.prepare, self.db, "SELECT * FROM '"..self.name.."' WHERE key = ?")

  if not state then return self:__error(err)
  else
      local data = err:bind(key):step()
      err:close()
      if data == nil then return nil end

      local value, err_ = self:decode(data[2])
      if value == self.err then return self:__error(err_) end

      if not nocache and type(self.cache) == "table" and self.options.cache then
          self.cache[data[1]] = value
      end
      return value
  end
end

---fetch all data from the database
---@param nocache boolean whether or not to not cache fetched value
function smoldb:fetch_all(nocache)
  local state, err = pcall(self.db.prepare, self.db, "SELECT * FROM '"..self.name.."'")

  if not state then return self:__error(err)
  else
      local cache, row = {}, {}
      while err:step(row) do
          local value, err_ = self:decode(row[2])
          if value == self.err then return self:__error(err_) end

          cache[row[1]] = value
      end
      err:close()

      if not nocache and type(self.cache) == "table" and self.options.cache then
          self.cache = cache
      end
      return cache
  end
end

--- write value in database without updating cache
---@param key string
---@param value any
function smoldb:write(key, value)
  if type(key) ~= "string" then return self:__error("key must be a string") end

  local state, err = pcall(self.db.prepare, self.db, "INSERT OR REPLACE INTO '"..self.name.."' (key, value) VALUES (?, ?)")

  if not state then return self:__error(err)
  else
      local encoded = self:encode(value)
      err:bind(key, encoded):step()
      err:close()
  end
end

--- let you iterate throug thw whole database
function smoldb:iterator()
  local state, err = pcall(self.db.prepare, self.db, "SELECT * FROM '"..self.name.."'")

  if not state then return error(err) --have to throw
  else
      local row = {}
      table.insert(self.handles, err) -- if loop is broke, handle will not be closed
      return function() 
          local v = err:step(row)
          local value = self:decode(row[2])
          if v == nil then
              for _,i in ipairs(self.handles) do if i == err then table.remove(self.handles, _) end end
              err:close()
              return nil
          end
          return row[1], value
          
      end
  end
end

--- return a table containing all database's key
function smoldb:keys()
  local state, err = pcall(self.db.prepare, self.db, "SELECT key FROM '"..self.name.."'")

  if not state then return self:__error(err)
  else
      local cache, row = {}, {}
      while err:step(row) do
          table.insert(cache, row[1])
      end
      err:close()
      return cache
  end
end

--- return a table containing all database's values
function smoldb:values()
  local state, err = pcall(self.db.prepare, self.db, "SELECT value FROM '"..self.name.."'")

  if not state then return self:__error(err)
  else
      local cache, row = {}, {}
      while err:step(row) do
          local value, err_ = self:decode(row[1])
          if value == self.err then return self:__error(err_) end
          table.insert(cache, value)
      end
      err:close()
      return cache
  end
end

--- return random value from database
---@param count number number of values to return
---@param nocache boolean whether or not to not cache fetched value
function smoldb:random(count, nocache)
  count = count or 1
  if type(count) ~= "number" then return self:__error("count must be a number") end
  if count <= 0 then return self:__error("count must be a positive non null number") end

  local state, err = pcall(self.db.prepare, self.db, "SELECT * FROM '"..self.name.."' ORDER BY RANDOM() LIMIT ?")

  if not state then return self:__error(err)
  else
      err:bind(count)
      local cache, row = {}, {}
      while err:step(row) do
          local value, err_ = self:decode(row[2])
          if value == self.err then return self:__error(err_) end

          table.insert(cache, {key = row[1], value = value})
      end
      err:close()

      if not nocache and type(self.cache) == "table" and self.options.cache then
          
      end
      return table.unpack(cache)
  end
end

--- clear whole cache or just a key
---@param key string|nil key to clear, otherwise the whole cache
function smoldb:clear_cache(key)
  if not self.options.cache then return false end
  if key == nil then
      self.cache = {}
  elseif type(key) == "string" then
      self.cache[key] = nil
  else return self:__error("key must be a string or nil") end
end

--- return internal info of this database (name, version, created_date)
function smoldb:get_info()
  local state, err = pcall(self.db.prepare, self.db, "SELECT * FROM 'internal::smoldb' WHERE tbl = ?")

  if not state then return self:__error(err)
  else
      local data = err:bind(self.name):step()
      err:close()
      if data == nil then return nil end
      return {
          name = data[1],
          version = data[2],
          created_date = data[3]
      }
  end
end

--- export database with internal information
function smoldb:export()
  local all, err = self:fetch_all(true)
  if all == self.err then return self:__error(err) end

  local info, err = self:get_info()
  if info == self.err then return self:__error(err) end

  return {
      name = self.name,
      file = self.db_file,
      version = self._version,
      export_date = os.time(),
      created_date = info.created_date,
      data = all
  }
end

--- import database with internal information using self.decode !! destroy any previous data !!
---@param data table
function smoldb:import(data)
  if type(data) ~= "table" then return self:__error("data to import must be a table") end
  
  if type(data.data) ~= "table" then return self:__error("missing data") end

  self:destroy(self.name)

  local state, err = pcall(self.db.prepare, self.db, "INSERT OR REPLACE INTO '"..self.name.."' (key, value) VALUES (?, ?)")
  if state == self.err then return self:__error(err) end

  for k, v in pairs(data.data) do
      local parsed, err_ = self:encode(v)
      if parsed == self.err then return self:__error(err_) end
      err:reset():clearbind():bind(k, parsed):step()
  end
  err:close()
end

-- minified version of msgpack in wait of lit package fix
local a=math.floor;local b=math.ceil;local c=math.huge;local d=string.char;local e=string.byte;local f=string.sub;local g=require('bit')local h=g.rshift;local i=g.lshift;local j=g.band;local k=g.bor;local l=table.concat;local m=require('ffi')local n=m.new("double[1]")local o=m.new("float[1]")local p=m.cast;local q=m.copy;local r;do local s=m.new("int16_t[1]")s[0]=1;local t=m.cast("uint8_t*",s)r=t[0]==0 end;local u=m.typeof('uint8_t[?]')local function v(w)return d(h(w,8),j(w,0xff))end;local function x(w)return d(h(w,24),j(h(w,16),0xff),j(h(w,8),0xff),j(w,0xff))end;local function y(z,A)return k(i(e(z,A),8),e(z,A+1))end;local function B(z,A)return k(i(e(z,A),24),i(e(z,A+1),16),i(e(z,A+2),8),e(z,A+3))end;local function C(D)local E=type(D)if E=="nil"then return"\xc0"elseif E=="boolean"then return D and"\xc3"or"\xc2"elseif E=="number"then if D==c or D==-c or D~=D then o[0]=D;local F=p("uint8_t*",o)if r then return d(0xCA,F[0],F[1],F[2],F[3])else return d(0xCA,F[3],F[2],F[1],F[0])end elseif a(D)~=D then n[0]=D;local F=p("uint8_t*",n)if r then return d(0xCB,F[0],F[1],F[2],F[3],F[4],F[5],F[6],F[7])else return d(0xCB,F[7],F[6],F[5],F[4],F[3],F[2],F[1],F[0])end else if D>=0 then if D<0x80 then return d(D)elseif D<0x100 then return"\xcc"..d(D)elseif D<0x10000 then return"\xcd"..v(D)elseif D<0x100000000 then return"\xce"..x(D)else return"\xcf"..x(a(D/0x100000000))..x(D%0x100000000)end else if D>=-0x20 then return d(0x100+D)elseif D>=-0x80 then return"\xd0"..d(0x100+D)elseif D>=-0x8000 then return"\xd1"..v(0x10000+D)elseif D>=-0x80000000 then return"\xd2"..x(0x100000000+D)elseif D>=-0x100000000 then return"\xd3\xff\xff\xff\xff"..x(0x100000000+D)else local G=b(D/0x100000000)local H=D-G*0x100000000;if H==0 then G=0x100000000+G else G=0xffffffff+G;H=0x100000000+H end;return"\xd3"..x(G)..x(H)end end end elseif E=="string"then local I=#D;if I<0x20 then return d(k(0xa0,I))..D elseif I<0x100 then return"\xd9"..d(I)..D elseif I<0x10000 then return"\xda"..v(I)..D elseif I<0x100000000 then return"\xdb"..x(I)..D else error("String too long: "..I.." bytes")end elseif E=="cdata"then local I=m.sizeof(D)D=m.string(D,I)if I<0x100 then return"\xc4"..d(I)..D elseif I<0x10000 then return"\xc5"..v(I)..D elseif I<0x100000000 then return"\xc6"..x(I)..D else error("Buffer too long: "..I.." bytes")end elseif E=="table"then local J=false;local K=1;local L=0;for M in pairs(D)do if type(M)~="number"or M<1 or M>10 and M~=K then J=true;break else L=M;K=K+1 end end;if J then local N=0;local O={}for M,P in pairs(D)do O[#O+1]=C(M)O[#O+1]=C(P)N=N+1 end;D=l(O)if N<16 then return d(k(0x80,N))..D elseif N<0x10000 then return"\xde"..v(N)..D elseif N<0x100000000 then return"\xdf"..x(N)..D else error("map too big: "..N)end else local O={}local I=L;for Q=1,I do O[Q]=C(D[Q])end;D=l(O)if I<0x10 then return d(k(0x90,I))..D elseif I<0x10000 then return"\xdc"..v(I)..D elseif I<0x100000000 then return"\xdd"..x(I)..D else error("Array too long: "..I.."items")end end else error("Unknown type: "..E)end end;local R,S;local function T(z,A)local U=e(z,A+1)if U<0x80 then return U,1 elseif U>=0xe0 then return U-0x100,1 elseif U<0x90 then return R(j(U,0xf),z,A,A+1)elseif U<0xa0 then return S(j(U,0xf),z,A,A+1)elseif U<0xc0 then local V=1+j(U,0x1f)return f(z,A+2,A+V),V elseif U==0xc0 then return nil,1 elseif U==0xc2 then return false,1 elseif U==0xc3 then return true,1 elseif U==0xcc then return e(z,A+2),2 elseif U==0xcd then return y(z,A+2),3 elseif U==0xce then return B(z,A+2)%0x100000000,5 elseif U==0xcf then return B(z,A+2)%0x100000000*0x100000000+B(z,A+6)%0x100000000,9 elseif U==0xd0 then local w=e(z,A+2)return w>=0x80 and w-0x100 or w,2 elseif U==0xd1 then local w=y(z,A+2)return w>=0x8000 and w-0x10000 or w,3 elseif U==0xd2 then return B(z,A+2),5 elseif U==0xd3 then local G=B(z,A+2)local H=B(z,A+6)if H<0 then G=G+1 end;return G*0x100000000+H,9 elseif U==0xd9 then local V=2+e(z,A+2)return f(z,A+3,A+V),V elseif U==0xda then local V=3+y(z,A+2)return f(z,A+4,A+V),V elseif U==0xdb then local V=5+B(z,A+2)%0x100000000;return f(z,A+6,A+V),V elseif U==0xc4 then local F=e(z,A+2)local V=2+F;return u(F,f(z,A+3,A+V)),V elseif U==0xc5 then local F=y(z,A+2)local V=3+F;return u(F,f(z,A+4,A+V)),V elseif U==0xc6 then local F=B(z,A+2)%0x100000000;local V=5+F;return u(F,f(z,A+6,A+V)),V elseif U==0xca then if r then local W=f(z,2,5)q(o,W,#W)else local W=d(e(z,A+5),e(z,A+4),e(z,A+3),e(z,A+2))q(o,W,#W)end;return o[0],5 elseif U==0xcb then if r then local W=f(z,2,9)q(n,W,#W)else local W=d(e(z,A+9),e(z,A+8),e(z,A+7),e(z,A+6),e(z,A+5),e(z,A+4),e(z,A+3),e(z,A+2))q(n,W,#W)end;return n[0],9 elseif U==0xdc then return S(y(z,A+2),z,A,A+3)elseif U==0xdd then return S(B(z,A+2)%0x100000000,z,A,A+5)elseif U==0xde then return R(y(z,A+2),z,A,A+3)elseif U==0xdf then return R(B(z,A+2)%0x100000000,z,A,A+5)else error("TODO: more types: "..string.format("%02x",U))end end;function S(N,z,A,X)local Y={}for Q=1,N do local V;Y[Q],V=T(z,X)X=X+V end;return Y,X-A end;function R(N,z,A,X)local Z={}for _=1,N do local V,M;M,V=T(z,X)X=X+V;Z[M],V=T(z,X)X=X+V end;return Z,X-A end;
msgpack = {encode=C,decode=function(z,A)return T(z,A or 0)end}

local smoldb_meta = {
  __call = function(self, name, options) return self:connect(name, options) end,
}
return setmetatable(smoldb, smoldb_meta)