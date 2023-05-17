# Smoldb

A Lua library that allows you to interface a slite3 database with no sqlite query.

A big thanks to [Enmap](https://enmap.evie.dev/), which heavily inspired my work.

## Summary
---
1. [Installation](#Installation)
2. [Usage](#Usage)
3. [Documentation](#Documentation)
    1. [Properties](#Properties)
    2. [Functions](#Functions)
4. [Changelog](#Changelog)
5. [License](#License)
---

## Installation

You can install table-watcher using [lit](https://github.com/luvit/lit). Run the following command:

```shell
$ lit install lil-evil/smoldb
```

Dependencies :
- [SinisterRectus/sqlite3](https://github.com/SinisterRectus/lit-sqlite3)
- [lil-evil/table-watcher](https://github.com/lil-evil/table-watcher)
## Usage

To use table-watcher in your Lua project, you need to require the module:

```lua
local smoldb = require("smoldb")
local db = smoldb("data") -- open or create ./smoldb.sqlite

db:set("userid", {name="john", surname="doe"})
db:get("userid").age = 18

p(db:get("userid"))
```

## Documentation
You can build a documentation with [ldoc](https://github.com/lunarmodules/LDoc)

Some things and aspects of the library may not be documented, and I'm really sorry if so. If you need help open an issue on github and i'll help you.

## Properties
### `smoldb.name`
Database name (represent the table name)

### `smoldb.db_file`
Sqlite file

### `smoldb.cache`
If cache is activated, store all cached data

### `smoldb.options`
options provided to smoldb. Do not modify

### `smoldb.db`
Underlying connection (see [SinisterRectus/sqlite3](https://github.com/SinisterRectus/lit-sqlite3))

### `smoldb.handles`
All unclosed stmt. Do not modify


## Functions

### `smoldb:connect(name, options)`
Initialize and connect to the database
**Parameters:**
- `name`: if nil or empty string, database reside on memory
- `options`
    - `dir`: the directory where the database is located
    - `file`:  the file where the database is located
    - `mode`: "ro", "rw", "rwc" (default)
    - `wal`: see https://www.sqlite.org/wal.html
    - `cache`: whether or not to cache data that have been fetch
    - `throw`: if true, functions are allowed to call error() instead of returning (nil, "error")
    - `packer`: data serializer, default json.encode
    - `unpacker`: data deserializer, default json.decode

**Returns:**
- `smoldb`: smoldb instance

**Notes**:
- `options.packer` should be a function with the following args and return : 
    - successful encode : function(data)->encoded
    - any error : function(data)->state, error

- `options.unpacker` should be a function with the following args and return : 
    - successful decode : function(data)->encoded, length_read
    - any error : function(data)->state, length_read, error

### `smoldb:close()`
close all handles and exit properly 

**Parameters:** none

**Returns:** none

### `smoldb:size()`
Get the number of items in the database

**Parameters:** none

**Returns:**
- `number`: number of items.

### `smoldb:get(key)`
Return the key's value or nil

**Parameters:**
- `key`: the key to return

**Returns:**
- `data`: Value for the given key

### `smoldb:set(key, value)`
Set a value in the database

**Parameters:**
- `key`: the key to set the value to
- `value`: the value to set

**Returns:** none

### `smoldb:ensure(key, default)`
Return the key's value or set it to the default value if provided and return it

**Parameters:**
- `key`: the key to return
- `default`: default value if key does not exist

**Returns:**
- `data`: Value for the given key

### `smoldb:has(key)`
Return whether or not the key exists

**Parameters:**
- `key`: the key to return

**Returns:**
- `data`: Value for the given key

### `smoldb:delete(key)`
Delete a key if it exists

**Parameters:**
- `key`: the key to delete

**Returns:** none

### `smoldb:merge(key, value)`
Merge database table with new table

**Parameters:**
- `key`: the key to merge to
- `value`: the value to merge

**Returns:** none

### `smoldb:fetch(key, force, nocache)`
Fetch data from the database or return cached value

**Parameters:**
- `key`: the key to fetch
- `force`: whether or not to ignore cached value and force database's fetch
- `nocache`: whether or not to not cache fetched value

**Returns:**
- `data`: Value for the given key

### `smoldb:fetch_all(nocache)`
Fetch all data from the database

**Parameters:**
- `nocache`: whether or not to not cache fetched value

**Returns:**
- `data`: all the database as {key1=value1, key2=value2}

### `smoldb:write(key, value)`
Write value in database without updating cache

**Parameters:**
- `key`: the key to set the value to
- `value`: the value to set

**Returns:** none

### `smoldb:iterator()`
Fetch all data from the database

**Parameters:** none

**Returns:**
- `next`: iterator function

### `smoldb:keys()`
Return a table containing all database's key

**Parameters:** none

**Returns:**
- `data`: all the database keys

### `smoldb:values()`
Return a table containing all database's values

**Parameters:** none

**Returns:**
- `data`: all the database values

### `smoldb:random(count, nocache)`
Return a table containing all database's values

**Parameters:**
- `count`: number of values to return
- `nocache`: whether or not to not cache fetched value

**Returns:**
- `data`: random keys got 

### `smoldb:clear_cache(key)`
Clear whole cache or just a key

**Parameters:**
- `key`: key to clear, otherwise the whole cache

**Returns:** none

### `smoldb:get_info()`
Return internal info of this database (name, version, created_date)

**Parameters:** none

**Returns:**
- `data`: {name, version, created_date}

### `smoldb:destroy(name)` **!! No going back !!**
Completly destroy any data and clear internal information about this database

**Parameters:**
- `name`: database's name. default to self.name

**Returns:** none

### `smoldb:export()`
Export database with internal information

**Parameters:** none

**Returns:**
- `data`: exported data as a table

### `smoldb:import(data)` **!! Destroy any previous data !!**
Import database with internal information using self.decode 

**Parameters:**
- `data`: previously exported database

**Returns:** none

### `smoldb:encode(data)`
Encode given data using custom packer or json.encode by default

**Parameters:**
- `data`: any data supported by the encoder

**Returns:**
- `encoded`: encoded data

### `smoldb:decode(data)`
Decode given data using custom unpacker or json.decode by default

**Parameters:**
- `data` : any data supported by the decoder

**Returns:**
- `decoded`: decoded data

### `smoldb:__error(err)`
throw or return nil, "error". internal syntax sugar

**Parameters:**
- `err` : error message

**Returns:** none

## Changelog
You can see the full changelog [here](./changelog.md).

## License
This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for more information.