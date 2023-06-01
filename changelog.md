# 1.0.0 `first release`

# 1.0.1
- correction of smoldb:export not giving a file name for memory databases
- other smoll fix

# 1.1.0 `breaking changes`
- smoll fixes
- added annoying messages for breaking changes
- added complete tests
- change of default packer/unpacker from json to message pack

=> correct json inability to reflect lua table (both an array and object, which are two different type in json) and performance gain