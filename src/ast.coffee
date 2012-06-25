{uglify, parser} = require 'uglify-js'

class AST
  constructor: (src, exigent_mode = false, embed_tokens = false) ->
    if Array.isArray src
      @ast = src
    else
      @ast = parser.parse src, exigent_mode, embed_tokens

  # find require calls
  findRequires: ->
    requires = []
    @walk
      call: (expr, args) ->
        # if require is being called
        if expr[1] == 'require'
          # we only care about the first argument, which is our requirement
          requires.push args[0][1]
    requires

  # update require calls using provided map
  updateRequires: (map) ->
    @transform
      call: (expr, args) ->
        if expr[1] == 'require'
          # return updated node
          update = map[args[0][1]]
          ['call',
            ['name', 'require'],
              [['string', update]]]
    @

  walk: (transforms) ->
    w = uglify.ast_walker()
    w.with_walkers transforms, => w.walk @ast

  transform: (transforms) ->
    w = uglify.ast_walker()
    @ast = w.with_walkers transforms, => w.walk @ast

  minify: ->
    @ast = uglify.ast_squeeze uglify.ast_mangle @ast
    @

  toString: (beautify = true, indent_start = 4, indent_level = 2) ->
    uglify.gen_code @ast,
      beautify: beautify
      indent_start: indent_start
      indent_level: indent_level

module.exports =
  AST: AST
  parse: (src, exigent_mode, embed_tokens) ->
    new AST src, exigent_mode, embed_tokens
