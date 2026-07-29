--!nonstrict

local function render()
  panel.render(ui.column({ padding = 24 }, {
    ui.label({ text = noctalia.tr("panel.title") }),
  }))
end

function onOpen(_context)
  render()
end
