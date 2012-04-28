require "moon"
require "moonscript"

require "lfs"
require "cosmo"
require "yaml"
discount = require "discount"

module "sitegen", package.seeall

require "sitegen.html"

import insert, concat, sort from table
import dump, extend, bind_methods, run_with_scope from moon

export create_site, register_plugin
export Site, SiteFile, Plugin, HTMLRenderer, MarkdownRenderer

plugins = {}
register_plugin = (plugin) ->
  plugin\on_register!  if plugin.on_register
  table.insert plugins, plugin

require "sitegen.common"
import Cache from require "sitegen.cache"

log = (...) ->
  print ...

require "lpeg"

-- replace all template vars in text not contained in a
-- code block
fill_ignoring_pre = (text, context) ->
  import P, R, S, V, Ct, C from lpeg

  string_patt = (delim) ->
    delim = P(delim)
    delim * (1 - delim)^0 * delim

  strings = string_patt"'" + string_patt'"'

  open = P"<code" * (strings + (1 - P">"))^0 * ">"
  close = P"</code>"

  Code = V"Code"
  code = P{
    Code
    Code: open * (Code + (1 - close))^0 * close
  }

  code = code / (text) -> {"code", text}

  other = (1 - code)^1 / (text) ->
    {"text", text}

  document = Ct((code + other)^0)
  -- parse to parts to avoid metamethod/c-call boundary
  parts = document\match text
  filled = for part in *parts
    t, body = unpack part
    body = cosmo.f(body) context if t == "text"
    body

  table.concat filled

-- template_helpers can yield if they decide to change the
-- entire body. This triggers the render to happen again
-- with the updated tpl_scope.
-- see indexer
render_until_complete = (tpl_scope, render_fn) ->
  out = nil
  while true
    co = coroutine.create ->
      out = render_fn!
      nil

    pass, altered_body = assert coroutine.resume co
    if altered_body
      tpl_scope.body = altered_body
    else
      break
  out

-- does two things:
-- 1) finds the sitefile, looking up starting from the curret dir
-- 2) lets us open files relative to where the sitefile is
class SiteFile
  new: (@name="site.moon") =>
    dir = lfs.currentdir!
    depth = 0
    while dir
      path = Path.join dir, name
      if Path.exists path
        @file_path = path
        @rel_path = ("../")\rep depth
        @make_io!
        return
      dir = Path.up dir
      depth += 1

    throw_error "failed to find sitefile: " .. name

  make_io: =>
    -- performs operations relative to sitefile
    @io = {
      -- load a file relative to the sitepath
      open: (fname, ...) ->
        path = Path.join(@rel_path, fname)
        print bright_yellow"+ opening: " .. path
        io.open path, ...
    }

  get_site: =>
    print bright_yellow"Using:", Path.join @rel_path, @name

    fn = moonscript.loadfile @file_path
    -- sitefiles have \write! on the bottom, disable it
    site = nil
    run_with_scope fn, {
      sitegen: extend {
        create_site: (fn) ->
          site = sitegen.create_site fn, Site self
          site.write = ->
          site
      }, sitegen
    }

    site.write = nil -- restore default write
    site


class Plugin -- uhh
  new: (@tpl_scope) =>

class Renderer
  new: (@pattern) =>
  render: -> error "must provide render method"
  can_render: (fname) =>
    nil != fname\match @pattern

  parse_header: (text) =>
    header = {}
    s, e = text\find "%-%-\n"
    if s
      header = yaml.load text\sub 1, s - 1
      text = text\sub e

    text, header

  render: (text, site) =>
    @parse_header text

class HTMLRenderer extends Renderer
  ext: "html"
  pattern: convert_pattern "*.html"

class MarkdownRenderer extends Renderer
  ext: "html"
  pattern: convert_pattern "*.md"
  pre_render: {}

  render: (text, page) =>
    text, header = @parse_header text

    for filter in *@pre_render
      text = filter text, page

    discount(text), header

class MoonRenderer extends Renderer
  ext: "html"
  pattern: convert_pattern "*.moon"

  -- this does some crazy chaining
  render: (text, page) =>
    scopes = {}

    context = setmetatable {}, {
      __index: (key) =>
        for i=#scopes,1,-1
          val = scopes[i][key]
          return val if val
    }

    base_scope = setmetatable {
      _context: -> context
      -- appends a scope to __index of the context
      format: (name) ->
        formatter = if type(name) == "string"
          require name
        else
          name

        insert scopes, formatter.make_context page, context
    }, __index: _G

    insert scopes, base_scope
    context.format "sitegen.formatters.default"

    fn = moonscript.loadstring text
    setfenv fn, context
    fn!
    context.render!

-- visible from init
class SiteScope
  new: (@site) =>
    @files = OrderSet!
    @copy_files = OrderSet!
    @filters = {}

  set: (name, value) => self[name] = value
  get: (name) => self[name]

  disable: (thing) =>
    @site[thing .. "_disabled"] = true

  add: (...) =>
    files = flatten_args ...
    @files\add fname for fname in *files

  copy: (...) =>
    files = flatten_args ...
    @copy_files\add fname for fname in *files

  filter: (pattern, fn) =>
    table.insert @filters, {pattern, fn}

  search: (pattern, dir=".", enter_dirs=false) =>
    pattern = convert_pattern pattern
    search = (dir) ->
      for fname in lfs.dir dir
        if not fname\match "^%."
          full_path = Path.join dir, fname
          if enter_dirs and "directory" == lfs.attributes full_path, "mode"
            search full_path
          elseif fname\match pattern
            if full_path\match"^%./"
              full_path = full_path\sub 3

            @files\add full_path

    search dir

  dump_files: =>
    print "added files:"
    for path in @files\each!
      print " * " .. path
    print!
    print "copy files:"
    for path in @copy_files\each!
      print " * " .. path

class Templates
  defaults: require "sitegen.default.templates"
  base_helpers: {
    render: (args) => -- render another page in current scope
      name = unpack args
      @site\Templates"."\fill name, @tpl_scope

    wrap: (args) =>
      tpl_name = unpack args
      throw_error "missing template name" if not tpl_name
      @template_stack\push tpl_name
      ""

    neq: (args) =>
      if args[1] != args[2]
        cosmo.yield {}
      else
        cosmo.yield _template: 2
      nil

    eq: (args) =>
      if args[1] == args[2]
        cosmo.yield {}
      else
        cosmo.yield _template: 2
      nil

    if: (args) =>
      if @tpl_scope[args[1]]
        cosmo.yield {}
      nil

    each: (args) =>
      list, name = unpack args
      if list
        list = flatten_args list
        for item in *list
          cosmo.yield { [(name)]: item }
      nil
  }

  new: (@dir, _io) =>
    @template_cache = {}
    @plugin_helpers = {}
    @base_helpers = extend @plugin_helpers, @base_helpers
    @io = _io or io

  fill: (name, context) =>
    tpl = @get_template name
    tpl context

  -- load an html (cosmo) template
  load_html: (name) =>
    file = @io.open Path.join @dir, name .. ".html"
    return if not file
    with cosmo.f file\read "*a"
      file\close!

  -- load a moonscript template
  load_moon: (name) =>
    file = @io.open Path.join @dir, name .. ".moon"
    return if not file
    fn = moonscript.loadstring file\read"*a", name
    file\close!

    (scope) ->
      tpl_fn = loadstring string.dump fn -- copy function
      source_env = getfenv tpl_fn

      setfenv tpl_fn, { :scope }

      html.build tpl_fn

  -- load a markdown template
  load_md: (name) =>
    file = @io.open Path.join @dir, name .. ".md"
    return if not file
    html = MarkdownRenderer\render file\read"*a"
    file\close!

    (scope) ->
      fill_ignoring_pre html, scope

  get_template: (name) =>
    if not @template_cache[name]
      tpl = nil
      -- look up exact file name
      base, ext = name\match "^(.-)%.([^/]*)$"
      if ext
        fn = self["load_"..ext]
        tpl = fn and fn self, base

      if not tpl
        for kind in *{"html", "moon"}
          tpl = self["load_"..kind] self, name
          break

      if tpl
        @template_cache[name] = tpl
      else
        -- still don't have it? load default
        @template_cache[name] = if @defaults[name]
          cosmo.f @defaults[name]
        else
          throw_error "Could not find template: " .. name if not file

    @template_cache[name]

-- an individual page
class Page
  __tostring: => table.concat { "<Page '",@source,"'>" }

  new: (@site, @source) =>
    @renderer = @site\renderer_for @source

    -- extract metadata
    @raw_text, @meta = @renderer\render @_read!, self
    @meta = @meta or {}

    @target = if @meta.target
      Path.join @site.config.out_dir, @meta.target .. "." .. @renderer.ext
    else
      @site\output_path_for @source, @renderer.ext

    filter = @site\filter_for @source
    if filter
      @raw_text = filter(@meta, @raw_text) or @raw_text

    -- expose meta in self
    cls = getmetatable self
    extend self, (key) => cls[key] or @meta[key]
    getmetatable(self).__tostring = Page.__tostring


  link_to: =>
    front = "^"..escape_patt @site.config.out_dir
    html.build ->
      a { @title, href: @target\gsub front, "" }

  -- write the file, return path to written file
  write: =>
    content = @_render!
    Path.mkdir Path.basepath @target
    with @site.io.open @target, "w"
      \write content
      \close!
    log "rendered", @source, "->", @target
    @target

  -- read the source
  _read: =>
    text = nil
    if not Path.exists @source
      throw_error "Can not open page source: " .. @source

    with @site.io.open @source
      text = \read"*a"
      \close!
    text

  _render: =>
    tpl_scope = {
      body: @raw_text
      generate_date: os.date!
    }

    helpers = @site\template_helpers tpl_scope, self

    base = Path.basepath @target
    parts = for i = 1, #split(base, "/") - 1 do ".."
    root = table.concat parts, "/"
    root = "." if root == ""
    helpers.root = root

    tpl_scope = extend tpl_scope, @meta, @site.user_vars, helpers
    @tpl_scope = tpl_scope

    tpl_scope.body = render_until_complete tpl_scope, ->
      fill_ignoring_pre tpl_scope.body, tpl_scope

    -- templates
    @template_stack = Stack!

    -- find the wrapping template
    @template_stack\push if @meta.template == nil
      @site.config.default_template
    else
      @meta.template

    while #@template_stack > 0
      tpl_name = @template_stack\pop!
      stack_height = #@template_stack
      tpl_scope.body = render_until_complete tpl_scope, ->
        -- unroll any templates pushed from previous render attempt
        while #@template_stack > stack_height
          @template_stack\pop!

        @site.templates\fill tpl_name, tpl_scope

    tpl_scope.body

-- a webpage
class Site
  __tostring: => "<Site>"

  config: {
    template_dir: "templates/"
    default_template: "index"
    out_dir: "www/"
    write_gitignore: true
  }

  new: (@sitefile=nil) =>
    @io = @sitefile and @sitefile.io or io

    @templates = @Templates @config.template_dir

    @scope = SiteScope self
    @cache = Cache!

    @user_vars = {}
    @written_files = {}

    @renderers = {
      MarkdownRenderer
      HTMLRenderer
      MoonRenderer
    }

    @plugins = OrderSet plugins
    -- extract aggregators from plugins
    @aggregators = {}
    for plugin in @plugins\each!
      if plugin.type_name
        for name in *make_list plugin.type_name
          @aggregators[name] = plugin

      if plugin.on_site
        plugin\on_site self

  Templates: (path) => Templates path, @io

  plugin_scope: =>
    scope = {}
    for plugin in @plugins\each!
      if plugin.mixin_funcs
        for fn_name in *plugin.mixin_funcs
          scope[fn_name] = bound_fn plugin, fn_name

    scope

  init_from_fn: (fn) =>
    bound = bind_methods @scope
    bound = extend @plugin_scope!, bound
    run_with_scope fn, bound, @user_vars

  output_path_for: (path, ext) =>
    if path\match"^%./"
      path = path\sub 3

    path = path\gsub "%.[^.]+$", "." .. ext
    Path.join @config.out_dir, path

  renderer_for: (path) =>
    for renderer in *@renderers
      if renderer\can_render path
        return renderer

    throw_error "Don't know how to render: " .. path

  -- TODO: refactor to use this?
  write_file: (fname, content) =>
    full_path = Path.join @config.out_dir, fname
    Path.mkdir Path.basepath full_path

    with @io.open full_path, "w"
      \write content
      \close!

    table.insert @written_files, full_path

  -- strips the out_dir from the file paths
  write_gitignore: (written_files) =>
    with @io.open @config.out_dir .. ".gitignore", "w"
      patt = "^" .. escape_patt(@config.out_dir) .. "(.+)$"
      relative = [fname\match patt for fname in *written_files]
      \write concat relative, "\n"
      \close!

  filter_for: (path) =>
    path = Path.normalize path
    for filter in *@scope.filters
      patt, fn = unpack filter
      if path\match patt
        return fn
    nil

  -- get template helpers from plugins
  -- template plugins instances with tpl_scope
  template_helpers: (tpl_scope, page) =>
    helpers = {}
    for plugin in @plugins\each!
      if plugin.tpl_helpers
        p = plugin tpl_scope
        for helper_name in *plugin.tpl_helpers
          helpers[helper_name] = (...) ->
            p[helper_name] p, ...

    -- give the page to base helpers as first arg
    base = setmetatable {}, {
      __index: (_, name) ->
        fn = @templates.base_helpers[name]
        if type(fn) != "function"
          fn
        else
          (...) -> fn page, ...
    }

    extend helpers, base

  -- write the entire website
  write: (filter_files=false) =>
    pages = for path in @scope.files\each!
      if not filter_files or filter_files[path]
        page = Page self, path
        -- TODO: check dont_write
        for t in *make_list page.meta.is_a
          plugin = @aggregators[t]
          throw_error "Unknown `is_a` type: " .. t if not plugin
          plugin\on_aggregate page
        page

    written_files = for page in *pages
      page\write!

    if not filter_files
      -- copy files
      for path in @scope.copy_files\each!
        target = Path.join @config.out_dir, path
        print "copied", target
        table.insert written_files, target
        Path.copy path, target

      -- write plugins
      for plugin in @plugins\each!
        plugin\write self if plugin.write

      -- gitignore
      if @config.write_gitignore
        -- add other written files
        table.insert written_files, file for file in *@written_files
        @write_gitignore written_files

    @cache\write!

create_site = (init_fn, site=Site!) ->
  with site
    \init_from_fn init_fn
    .scope\search "*md" unless .autoadd_disabled

-- plugin providers
require "sitegen.deploy"
require "sitegen.indexer"
require "sitegen.extra"
require "sitegen.blog"
require "sitegen.feed"

