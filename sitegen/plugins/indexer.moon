
require "sitegen.common"
html = require "sitegen.html"
cosmo = require "cosmo"
lpeg = require "lpeg"

import insert, concat from table
import Plugin from require "sitegen.plugin"
import slugify from require "sitegen.common"

render_index = (index) ->
  yield_index = (index) ->
    for item in *index
      if item.depth
        cosmo.yield _template: 2
        yield_index item
        cosmo.yield _template: 3
      else
        cosmo.yield name: item[1], target: item[2]

  tpl = [==[
		<ul>
		$index[[
			<li><a href="#$target">$name</a></li>
		]], [[ <ul> ]] , [[ </ul> ]]
		</ul>
  ]==]

  cosmo.f(tpl) index: -> yield_index index

-- filter to build index for headers
build_from_html = (body, meta, opts={}) ->
  headers = {}

  opts.min_depth = opts.min_depth or 1
  opts.max_depth = opts.max_depth or 9

  current = headers
  fn = (body, i) ->
    i = tonumber i

    if i >= opts.min_depth and i <= opts.max_depth
      if not current.depth
        current.depth = i
      else
        if i > current.depth
          current = parent: current, depth: i
        else
          while i < current.depth and current.parent
            insert current.parent, current
            current = current.parent

          current.depth = i if i < current.depth

    slug = slugify html.decode body
    insert current, {body, slug}
    concat {
      '<h', i, '><a name="',slug,'"></a>', body, '</h', i, '>'
    }

  lpeg = require "lpeg"
  import P, R, Cmt, Cs, Cg, Cb, C from lpeg

  nums = R("19")
  open = P"<h" * Cg(nums, "num") * ">"

  close = P"</h" * C(nums) * ">"
  close_pair = Cmt close * Cb("num"), (s, i, a, b) -> a == b
  tag = open * C((1 - close_pair)^0) * close

  patt = Cs((tag / fn + 1)^0)
  out = patt\match(body)

  while current.parent
    insert current.parent, current
    current = current.parent

  out, headers

class IndexerPlugin extends Plugin
  @build_from_html: build_from_html

  tpl_helpers: { "index" }

  new: (@site) =>
    @current_index = nil

  index: (page) =>
    unless @current_index
      assert page.tpl_scope.render_source, "attempting to render index with no body available (are you in cosmo?)"
      body, @current_index = build_from_html page.tpl_scope.render_source
      coroutine.yield body

    render_index @current_index

