program = require 'jade/node_modules/commander'
version = require('../package.json').version

list = (val) -> val.split ','

program
  .version(version)
  .usage('--entry <input> [-output <output>, --libs <lib1,lib2>]')
  .option('-e, --entry <entry-point>', 'entry point to your code')
  .option('-o, --output <file>', 'where to compile your code to')
  .option('-l, --libs <files>', 'files which should be prepended to compiled output', list)
  .option('-m, --minify', 'minify bundled code')
  .parse(process.argv)

help = ->
  console.log program.helpInformation()
  process.exit()

help() unless program.entry

require('./build')
  entry: program.entry
  output: program.output
  before: program.libs
  minify: program.minify
