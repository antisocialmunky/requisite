compilers = require './compilers'
crypto    = require 'crypto'
fs        = require 'fs'
resolver  = require './resolver'
{concat, fmtDate, uniq} = require './utils'
{dirname, extname, join} = require 'path'
{parse, minify} = require './ast'

module.exports = createBundler = (opts) ->
  defaults =
    # Scripts which should be bundled after entry module and dependencies.
    after: []
    # Scripts which should be bundled before entry module and dependencies.
    before: []
    # Whether to minify or not.
    minify: false
    # Whether to automatically require the entry module.
    requireEntry: true
    # AST transformations/walkers
    astTransforms: []
    astWalkers: []
    astFilters: []
    # Hook to replace the function which wraps each module
    wrapper: null
    # Hook to replace prelude which is included
    prelude: null
    # Whether to include compiler related hooks
    compilerHooks: true

  for k,v of defaults
    opts[k] ?= v

  # Update compilers with custom compilers
  if opts.compilers
    for k,v of opts.compilers
      compilers[k] = v

  # Build resolver.
  {resolve} = require('./resolver')(dirname opts.entry)

  # Cache parsed files
  cache = {}

  # Find all dependencies
  find = (opts, cb) ->
    count = 0
    entry = opts.entry
    hooks =
      after: {}
      before: {}

    # Hook into module compilation
    addHooks = (name, {after, before}) ->
      if not hooks.after[name] and after
        hooks.after[name] = after()

      if not hooks.before[name] and before
        hooks.before[name] = before()

    # Create relative (to entry point) filename aliases
    alias = do ->
      base = dirname(entry).length
      (filename) ->
        filename = filename.replace(/\\/g, '/')
        if /node_modules/i.test filename
          idx = filename.indexOf '/node_modules'
          base = idx
        name = filename.substring base
        name = name.split('.')
        name.pop()
        name.join('.').replace /\/index$/, ''

    # Parse dependencies
    iterate = (req, parent) ->
      # Test whether we are requiring an absolute/relative file or a modules in node_modules
      if parent and /^\.\/|\/|^\w\:\\/.test req
        path = join parent.base, req
      else
        path = req

      resolve path, (err, filename) ->
        if parent
          # Add to parent's map of resolved modules
          parent.resolved[req] = filename

        file =
          base: dirname filename
          body: ''
          ext: extname(filename).substring 1
          filename: filename
          mtime: null
          aliases: [alias filename]
          requireAs: req
          requires: []
          resolved: {}

        # Iterate over dependencies
        walk = (file) ->
          count += file.requires.length
          for req in file.requires
            # We must go deeper...
            iterate req, file
          if count > 0
            --count
          else
            # Done recursing, setup hooks and return ordered dependencies
            opts.hooks = hooks
            cb null, (mod for filename, mod of cache)

        fs.stat filename, (err, stat) ->
          throw err if err

          if (not cache[filename]?.mtime) or (cache[filename].mtime < stat.mtime)
            file.mtime = stat.mtime

            # Create a unique hash for this file
            shasum = crypto.createHash 'sha1'
            stream = fs.ReadStream filename
            stream.setEncoding 'utf8'

            body = ''

            stream.on 'data', (data) ->
              # Update hash
              shasum.update data
              body += data

            stream.on 'end', ->
              file.hash = shasum.digest('hex').substring 0, 10
              # Try to compile file using appropriate compiler
              try
                body = compilers[file.ext](body, filename)
              catch err
                throw new Error "Error: Failed to compile #{filename}"

              # Find all dependencies that are required
              file.ast = parse body
              file.requires = file.ast.findRequires()

              # Cache file
              cache[filename] = file

              # Add hooks
              if not parent and opts.requireEntry
                addHooks '__entry', after: -> "require('#{file.hash}');"
              addHooks file.ext, compilers[file.ext]

              # Walk dependencies
              walk file
          else
            # Use cached file
            file = cache[filename]

            # Add hooks
            if not parent and opts.requireEntry
              addHooks '__entry', after: -> "require('#{file.hash}');"
            addHooks file.ext, compilers[file.ext]

            # Walk dependencies
            walk file

    iterate entry

  # Bundles modules starting from an entry point
  bundle = (opts, cb) ->
    wrapper = opts.wrapper or wrap
    # Extra hooks to append/prepend supporting scripts requried by dependencies
    find opts, (err, modules) ->
      modules = (wrapper mod, opts for mod in modules)

      if opts.compilerHooks
        for k,v of opts.hooks.after
          modules.push if opts.minify then minify v else v
        for k,v of opts.hooks.before
          modules.unshift if opts.minify then minify v else v
      cb err, modules.join(if opts.minify then '' else '\n\n')

  # Wraps a required module in a define statement.
  wrap = (file, opts={}) ->
    # Map of require calls to file hashes

    map = {}
    for req, filename of file.resolved
      map[req] = cache[filename].hash

    # Generate AST with updated require calls.
    ast = file.ast.updateRequires(map)

    # Perform any extra AST manipulations
    for filter in opts.astFilters
      ast.call filter, opts
    for walker in opts.astWalkers
      ast.walk walker
    for transform in opts.astTransforms
      ast.transform transform

    if opts.minify
      "require.define(['#{file.hash}'], function (require, module, exports) {(function(){#{ast.toString minify: true}}).call(this)});"
    else
      source = file.filename
      aliases = JSON.stringify file.aliases.concat file.hash
      modified = fmtDate file.mtime
      """
      // source: #{source}
      // modified: #{modified}
      require.define(#{aliases}, function (require, module, exports) {(function(){
      #{ast.toString()}
      }).call(this)});
      """

  # Returns necessary prelude file.
  prelude = (opts, cb) ->
    if opts.prelude is false
      return cb null, ''

    path = opts.prelude ? join __dirname, if opts.minify then 'prelude-minify' else 'prelude'
    resolve path, (err, filename) ->
      fs.readFile filename, 'utf8', (err, data) ->
        ext = extname(filename).substring 1
        content = compilers[ext](data, filename)
        cb err, if opts.minify then minify content else content

  # Return JavaScript bundler.
  bundler =
    find: find
    wrap: wrap
    bundle: (cb) ->
      concat opts.before, opts, (err, before) ->
        prelude opts, (err, prelude) ->
          bundle opts, (err, bundle) ->
            concat opts.after, opts, (err, after) ->
              cb err, [before, prelude, bundle, after].join(if opts.minify then '' else '\n\n').trim()
