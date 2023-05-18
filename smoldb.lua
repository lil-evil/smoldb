  --[[lit-meta
    name = "lil-evil/smoldb"
    version = "1.0.1"
    dependencies = {
      "lil-evil/table-watcher",
      "SinisterRectus/sqlite3"
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
local json = require"json"

local table_watcher = require"table-watcher"
local sqlite = require"sqlite3"

local smoldb = {
  package = {version="1.0.1"},
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
---@param options.packer function data serializer, default json.encode
---@param options.unpacker function data deserializer, default json.decode
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
--- encode given data using custom packer or json.encode by default
---@param data any
function smoldb:encode(data)
  local packer = type(self.options.packer) == "function" and self.options.packer or json.encode
  
  local packed, error = packer(data)
  if error then 
      return self:__error(error)
  else
      return packed
  end
end
--- decode given data using custom unpacker or json.decode by default
---@param data string
function smoldb:decode(data)
  local unpacker = type(self.options.unpacker) == "function" and self.options.unpacker or json.decode
  
  local unpacked, _, error = unpacker(data)
  if error then 
      return self:__error(error)
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

  local data, error = self:fetch(key)
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
      self:set(key, default)
      data = default
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
      return #cache > 1 and cache or cache[1]
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

local smoldb_meta = {
  __call = function(self, name, options) return self:connect(name, options) end,
}
return setmetatable(smoldb, smoldb_meta)