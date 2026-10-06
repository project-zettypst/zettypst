return {
  autostart = true,
  root_dir = function(path)
    return vim.fs.root(path, ".zettypst")
  end,
  entries = {
    nodes = ".zettypst/host/nodes.typ",
    new = ".zettypst/host/new.typ",
    delete = ".zettypst/host/delete.typ",
    capture = ".zettypst/host/capture.typ",
  },
  capture = { bibliography = { path = "ref.bib" } },
  actions = {
    capture = {
      collect = function(ctx, done)
        require("zettypst.capture").collect(ctx, done)
      end,
    },
    new = {
      collect = function(_, done)
        vim.ui.input({ prompt = "Title: " }, function(title)
          done(title and title:match("%S") and { title = title } or nil)
        end)
      end,
    },
    delete = {
      collect = function(ctx, done)
        assert(ctx.current, "no unambiguous current node")
        vim.ui.select(
          { "Delete", "Force delete", "Cancel" },
          { prompt = "Delete " .. ctx.current.title .. "?" },
          function(choice)
            if choice == "Delete" or choice == "Force delete" then
              done({ id = ctx.current.id, force = choice == "Force delete" })
            else
              done(nil)
            end
          end
        )
      end,
    },
  },
  picker = {
    views = {
      {
        name = "title",
        text = function(n)
          return n.title
        end,
        weight = 10,
      },
      {
        name = "aliases",
        text = function(n)
          return n.metadata.aliases or {}
        end,
        weight = 5,
      },
      {
        name = "abstract",
        text = function(n)
          return n.metadata.abstract or ""
        end,
        weight = 0,
      },
    },
    filters = {
      active = {
        default = true,
        test = function(n)
          return type(n.metadata.relation) == "table" and n.metadata.relation.value == "active"
        end,
      },
    },
    display = {
      detail = function(n)
        return table.concat(n.metadata.tags or {}, ", ")
      end,
    },
  },
}
