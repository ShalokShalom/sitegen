local Plugin
Plugin = require("sitegen.plugin").Plugin
local trim_leading_white
trim_leading_white = require("sitegen.common").trim_leading_white
local html = require("sitegen.html")
local discount = require("discount")
local date = require("date")
local extend
extend = require("moon").extend
local insert
insert = table.insert
local render_feed
render_feed = function(root)
  local concat
  concat = function(list)
    return html.builders.raw()(html.build(function()
      return list
    end))
  end
  local format_date
  format_date = function(date)
    if date.fmt then
      return date:fmt("${http}")
    else
      return tostring(date)
    end
  end
  return html.build(function()
    return {
      raw([[<?xml version="1.0" encoding="utf-8"?>]]),
      rss({
        version = "2.0",
        channel({
          title(root.title),
          link(root.link),
          description(root.description),
          concat((function()
            local _accum_0 = { }
            local _len_0 = 1
            for _index_0 = 1, #root do
              local entry = root[_index_0]
              local parts = { }
              if entry.title then
                insert(parts, title(entry.title))
              end
              if entry.link then
                insert(parts, link(entry.link))
              end
              if entry.date then
                insert(parts, pubDate(format_date(entry.date)))
              end
              if entry.description then
                insert(parts, description(cdata(entry.description)))
              end
              local _value_0 = item(parts)
              _accum_0[_len_0] = _value_0
              _len_0 = _len_0 + 1
            end
            return _accum_0
          end)())
        })
      })
    }
  end)
end
local FeedPlugin
do
  local _parent_0 = Plugin
  local _base_0 = {
    mixin_funcs = {
      "feed"
    },
    on_site = function(self)
      self.feeds = { }
    end,
    feed = function(self, source, dest)
      local moonscript = require("moonscript.base")
      local fn = assert(moonscript.loadfile(source))
      return table.insert(self.feeds, {
        dest,
        fn()
      })
    end,
    write = function(self, site)
      if not (self.feeds[1]) then
        return 
      end
      site.logger:plain("feeds:", #self.feeds)
      local _list_0 = self.feeds
      for _index_0 = 1, #_list_0 do
        local feed = _list_0[_index_0]
        local dest, root = unpack(feed)
        root.description = root.description or ""
        for _index_1 = 1, #root do
          local entry = root[_index_1]
          entry.description = trim_leading_white(entry.description)
          extend(entry, root)
          local _exp_0 = entry.format
          if "markdown" == _exp_0 then
            entry.description = discount(entry.description)
          else
            entry.description = entry.description
          end
        end
        site:write_file(dest, render_feed(root))
      end
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  local _class_0 = setmetatable({
    __init = function(self, ...)
      return _parent_0.__init(self, ...)
    end,
    __base = _base_0,
    __name = "FeedPlugin",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        return _parent_0[name]
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  local self = _class_0
  self.render_feed = render_feed
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  FeedPlugin = _class_0
  return _class_0
end
